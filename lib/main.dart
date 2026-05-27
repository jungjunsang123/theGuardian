import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:math';
import 'dart:ui';

// Apple & Toss 스타일의 프리미엄 라이트 테마 컬러 세트
const Color appBg = Color(0xFFF2F4F6); // 토스 라이트 그레이 배경
const Color cardBg = Color(0xFFFFFFFF); // 완벽한 화이트 카드 배경
const Color textPrimary = Color(0xFF333D4B); // 토스 본문 다크 그레이
const Color textSecondary = Color(0xFF8B95A1); // 토스 부연 설명 그레이
const Color tossBlue = Color(0xFF3182F6); // 토스 블루
const Color tossRed = Color(0xFFF04452); // 토스 레드
const Color appleGray = Color(0xFFE5E8EB); // 라이트 회색 대용

// 6자리 랜덤 초대 코드 생성기
String _generateInviteCode() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final rnd = Random();
  return String.fromCharCodes(Iterable.generate(
      6, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
}

// -----------------------------------------------------------------------------
// 백그라운드 위치 서비스 초기화 및 시작 함수
// -----------------------------------------------------------------------------
Future<void> initializeBackgroundService(String uid) async {
  final service = FlutterBackgroundService();

  // 이미 실행 중이면 세션만 설정해 줍니다.
  final isRunning = await service.isRunning();
  if (isRunning) {
    service.invoke('setUid', {'uid': uid});
    return;
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'the_guardian_location',
      initialNotificationTitle: 'The Guardian 구동 중',
      initialNotificationContent: '백그라운드에서 실시간 위치를 보호하고 있습니다.',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );

  await service.startService();
  service.invoke('setUid', {'uid': uid});
}

@pragma('vm:entry-point')
bool onIosBackground(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  String? currentUid;

  service.on('setUid').listen((event) {
    if (event != null) {
      currentUid = event['uid'];
    }
  });

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // 백그라운드 위치 트래킹 스트림 시작
  Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 15, // 15미터 이상 이동 시 수집
    ),
  ).listen((Position position) async {
    if (currentUid == null) return;

    final userDocRef = FirebaseFirestore.instance.collection('users').doc(currentUid);
    final doc = await userDocRef.get();
    if (!doc.exists) return;

    final data = doc.data() as Map<String, dynamic>;
    final safeZones = data['safeZones'] as List<dynamic>? ?? [];

    bool isInsideAnySafeZone = false;
    String insideZoneName = '';

    // 모든 등록된 안심존(Safe Zone) 검사
    for (var zone in safeZones) {
      final double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        zone['latitude'],
        zone['longitude'],
      );
      if (distance <= (zone['radius'] ?? 100.0)) {
        isInsideAnySafeZone = true;
        insideZoneName = zone['name'] ?? '안심존';
        break;
      }
    }

    final battery = Battery();
    final int batteryLevel = await battery.batteryLevel;

    if (isInsideAnySafeZone) {
      // 안심존 내부인 경우: 배터리를 아끼기 위해 Firestore 업데이트 생략 (상태가 변경될 때만 1회 기록)
      final String? prevStatus = data['status'];
      if (prevStatus == 'safe_$insideZoneName') {
        return; // 쓰기 작업 생략
      }

      await userDocRef.update({
        'latitude': position.latitude,
        'longitude': position.longitude,
        'battery': batteryLevel,
        'status': 'safe_$insideZoneName',
        'lastActive': FieldValue.serverTimestamp(),
      });
    } else {
      // 안심존 외부일 때: 10분 주기로 위치 실시간 수집 및 Firestore 전송
      final Timestamp? lastActive = data['lastActive'] as Timestamp?;
      final now = DateTime.now();

      if (lastActive == null ||
          now.difference(lastActive.toDate()).inMinutes >= 10 ||
          data['status'] != 'moving') {
        
        await userDocRef.update({
          'latitude': position.latitude,
          'longitude': position.longitude,
          'battery': batteryLevel,
          'status': 'moving',
          'lastActive': FieldValue.serverTimestamp(),
        });

        // 7일 파기 대상 실시간 위치 기록을 서브컬렉션으로 누적
        await userDocRef.collection('history').add({
          'latitude': position.latitude,
          'longitude': position.longitude,
          'timestamp': FieldValue.serverTimestamp(),
        });
      }
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
    if (!kIsWeb) {
      // 네이버 지도 SDK 초기화 (Client ID 등록)
      await FlutterNaverMap().init(
        clientId: '2kij3oiucs',
        onAuthFailed: (e) => debugPrint('네이버 지도 인증 실패: $e'),
      );
    }
    await GoogleSignIn.instance.initialize(
      serverClientId: '246238512248-2foqjr7mkpifvkak6b8lsjhuq26j5us8.apps.googleusercontent.com',
    );
  } catch (e) {
    debugPrint('초기화 실패: $e');
  }
  runApp(const TheGuardianApp());
}

class TheGuardianApp extends StatelessWidget {
  const TheGuardianApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'The Guardian',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: appBg,
        primaryColor: tossBlue,
        colorScheme: const ColorScheme.light(
          primary: tossBlue,
          secondary: tossRed,
          surface: cardBg,
        ),
        fontFamily: 'Pretendard',
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: tossBlue),
              ),
            );
          }
          if (snapshot.hasData && snapshot.data != null) {
            return HomeScreen(user: snapshot.data!);
          }
          return const LoginScreen();
        },
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Toss & Apple 스타일의 바운스 터치 애니메이션 위젯 (TossBounce)
// -----------------------------------------------------------------------------
class TossBounce extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const TossBounce({super.key, required this.child, this.onTap});

  @override
  State<TossBounce> createState() => _TossBounceState();
}

class _TossBounceState extends State<TossBounce> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.94).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        _controller.forward();
        HapticFeedback.lightImpact();
      },
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap?.call();
      },
      onTapCancel: () {
        _controller.reverse();
      },
      child: ScaleTransition(
        scale: _scale,
        child: widget.child,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 로그인 화면 (LoginScreen)
// -----------------------------------------------------------------------------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = false;

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn.instance.authenticate();
      if (googleUser == null) {
        setState(() => _isLoading = false);
        return;
      }

      final GoogleSignInAuthentication googleAuth = googleUser.authentication;
      final OAuthCredential credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final User? user = userCredential.user;

      if (user != null) {
        final userDocRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
        final userDoc = await userDocRef.get();

        String inviteCode;
        String groupId;

        if (userDoc.exists && userDoc.data() != null) {
          final data = userDoc.data()!;
          inviteCode = data['inviteCode'] ?? _generateInviteCode();
          groupId = data['groupId'] ?? user.uid;
        } else {
          inviteCode = _generateInviteCode();
          groupId = user.uid;
        }

        await userDocRef.set({
          'uid': user.uid,
          'name': user.displayName ?? '이름 없음',
          'email': user.email ?? '이메일 없음',
          'photoUrl': user.photoURL ?? '',
          'lastActive': FieldValue.serverTimestamp(),
          'inviteCode': inviteCode,
          'groupId': groupId,
          'battery': 100,
          'latitude': 37.5665,
          'longitude': 126.9780,
          'geofenceLat': null,
          'geofenceLng': null,
          'geofenceName': null,
          'geofenceRadius': 100.0,
          'safeZones': [], // 다중 안심존 배열 초기화
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('구글 로그인 에러: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('로그인 실패: SHA-1이 등록되지 않았거나 네트워크 오류입니다. ($e)'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _signInAnonymously() async {
    setState(() => _isLoading = true);
    try {
      final UserCredential userCredential =
          await FirebaseAuth.instance.signInAnonymously();
      final User? user = userCredential.user;

      if (user != null) {
        final userDocRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
        final userDoc = await userDocRef.get();

        String inviteCode;
        String groupId;

        if (userDoc.exists && userDoc.data() != null) {
          final data = userDoc.data()!;
          inviteCode = data['inviteCode'] ?? _generateInviteCode();
          groupId = data['groupId'] ?? user.uid;
        } else {
          inviteCode = _generateInviteCode();
          groupId = user.uid;
        }

        await userDocRef.set({
          'uid': user.uid,
          'name': '테스트 기기(아이패드)',
          'email': 'test@guardian.local',
          'photoUrl': 'https://www.gstatic.com/images/branding/product/2x/avatar_anonymous_96dp.png',
          'lastActive': FieldValue.serverTimestamp(),
          'inviteCode': inviteCode,
          'groupId': groupId,
          'battery': 100,
          'latitude': 37.5665,
          'longitude': 126.9780,
          'geofenceLat': null,
          'geofenceLng': null,
          'geofenceName': null,
          'geofenceRadius': 100.0,
          'safeZones': [],
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('익명 로그인 에러: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('익명 로그인 실패: Firebase Console에서 익명 로그인을 활성화해야 합니다. ($e)'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, appBg],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(flex: 2),
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: tossBlue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.security,
                    size: 28,
                    color: tossBlue,
                  ),
                ),
                const SizedBox(height: 28),
                const Text(
                  '소중한 가족의 위치\n언제나 안전하게.',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    height: 1.35,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'The Guardian은 불필요한 배터리 소모 없이\n가족의 안심존 출입과 실시간 위치를 보호합니다.',
                  style: TextStyle(
                    fontSize: 15,
                    color: textSecondary,
                    height: 1.5,
                  ),
                ),
                const Spacer(flex: 3),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.shield, color: tossBlue, size: 24),
                      SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          '비밀번호 없이 구글 보안 연동만으로\n가장 안전하고 빠르게 가입할 수 있어요.',
                          style: TextStyle(
                            fontSize: 13,
                            color: textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _isLoading
                    ? const Center(child: CircularProgressIndicator(color: tossBlue))
                    : Column(
                        children: [
                          TossBounce(
                            onTap: _signInWithGoogle,
                            child: Container(
                              width: double.infinity,
                              height: 58,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.1),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Image.network(
                                    'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/1024px-Google_%22G%22_logo.svg.png',
                                    width: 22,
                                    height: 22,
                                    errorBuilder: (context, error, stackTrace) => const Icon(
                                      Icons.login,
                                      size: 22,
                                      color: tossBlue,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const Text(
                                    'Google 계정으로 시작하기',
                                    style: TextStyle(
                                      color: Color(0xFF1E293B),
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TossBounce(
                            onTap: _signInAnonymously,
                            child: Container(
                              width: double.infinity,
                              height: 50,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE8F3FF),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.phonelink_setup_outlined, color: tossBlue, size: 20),
                                  const SizedBox(width: 12),
                                  const Text(
                                    '임시 테스트 계정으로 시작하기',
                                    style: TextStyle(
                                      color: tossBlue,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 메인 화면 (HomeScreen)
// -----------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  final User user;

  const HomeScreen({super.key, required this.user});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _geocodingChannel = MethodChannel('com.theguardian.app/geocoding');
  
  final TextEditingController _inviteCodeController = TextEditingController();
  final TextEditingController _zoneNameController = TextEditingController();
  final TextEditingController _searchQueryController = TextEditingController();
  
  double? _selectedLat; // 검색으로 선택된 위치 위도
  double? _selectedLng; // 검색으로 선택된 위치 경도
  
  NaverMapController? _mapController;
  bool _isRegistering = false;
  bool _isUpdatingOverlays = false; // 마커 업데이트 재진입 방지
  Stream<DocumentSnapshot>? _userStream;
  Stream<QuerySnapshot>? _myGroupsStream;
  String _lastOverlayFingerprint = '';
  
  String _lastActiveGroupId = '';
  Stream<DocumentSnapshot>? _activeGroupStream;
  String _lastFamilyUidsFingerprint = '';
  Stream<QuerySnapshot>? _membersStream;

  @override
  void initState() {
    super.initState();
    // 로그인 시 백그라운드 구동에 필요한 위치 및 알림 권한을 요청합니다.
    _requestLocationPermissions();
    _userStream = FirebaseFirestore.instance.collection('users').doc(widget.user.uid).snapshots();
    _myGroupsStream = FirebaseFirestore.instance
        .collection('groups')
        .where('members', arrayContains: widget.user.uid)
        .snapshots();
  }

  @override
  void dispose() {
    _inviteCodeController.dispose();
    _zoneNameController.dispose();
    _searchQueryController.dispose();
    super.dispose();
  }

  // 위치 권한 요청 함수
  Future<void> _requestLocationPermissions() async {
    if (kIsWeb) return;
    var status = await Permission.location.request();
    if (status.isGranted) {
      await Permission.locationAlways.request();
      await Permission.notification.request();
      
      // 권한이 승인되면 실시간 백그라운드 위치 기록 서비스 기동
      await initializeBackgroundService(widget.user.uid);

      if (_mapController != null) {
        _mapController!.setLocationTrackingMode(NLocationTrackingMode.follow);
      }
    }
  }
  Future<void> _joinGroupWithCode(String code) async {
    code = code.trim().toUpperCase();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('초대 코드를 입력해 주세요.')),
      );
      return;
    }

    setState(() => _isRegistering = true);

    try {
      // 1. /groups 컬렉션에서 초대 코드 검색 (가장 보편적인 정상 그룹 합류 경로)
      final QuerySnapshot groupQuery = await FirebaseFirestore.instance
          .collection('groups')
          .where('inviteCode', isEqualTo: code)
          .limit(1)
          .get();

      if (groupQuery.docs.isNotEmpty) {
        final DocumentSnapshot groupDoc = groupQuery.docs.first;
        final String groupId = groupDoc.id;
        final Map<String, dynamic> groupData = groupDoc.data() as Map<String, dynamic>;
        final String groupName = groupData['name'] ?? '그룹';
        final List<dynamic> members = groupData['members'] ?? [];

        if (members.contains(widget.user.uid)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('이미 [$groupName] 그룹의 멤버입니다.'),
                backgroundColor: tossBlue,
              ),
            );
          }
          return;
        }

        // 그룹 멤버에 추가 및 activeGroupId 업데이트
        await FirebaseFirestore.instance.collection('groups').doc(groupId).update({
          'members': FieldValue.arrayUnion([widget.user.uid])
        });

        await FirebaseFirestore.instance.collection('users').doc(widget.user.uid).update({
          'activeGroupId': groupId,
          'groupId': groupId, // 하위 호환성 유지
        });

        if (mounted) {
          _inviteCodeController.clear();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('[$groupName] 그룹에 성공적으로 참여했어요!'),
              backgroundColor: Theme.of(context).colorScheme.secondary,
            ),
          );
        }
        return;
      }

      // 2. /groups에서 못 찾았을 경우, 하위 호환성을 위해 /users에서 초대 코드 검색 (신규 가입 유저 등의 대응)
      final QuerySnapshot userQuery = await FirebaseFirestore.instance
          .collection('users')
          .where('inviteCode', isEqualTo: code)
          .limit(1)
          .get();

      if (userQuery.docs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('해당 초대 코드를 가진 그룹이나 사용자를 찾을 수 없습니다. 다시 한번 확인해 주세요.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }

      final DocumentSnapshot targetUserDoc = userQuery.docs.first;
      final Map<String, dynamic> targetData = targetUserDoc.data() as Map<String, dynamic>;
      final String targetGroupId = targetData['groupId'] ?? targetUserDoc.id;
      final String targetName = targetData['name'] ?? '가족';

      if (targetUserDoc.id == widget.user.uid) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('본인의 코드는 등록할 수 없습니다.'),
              backgroundColor: tossRed,
            ),
          );
        }
        return;
      }

      // [VETERAN TOUCH] 상대방의 기본 그룹이 아직 생성되지 않은 상태 보안 충돌 사전 예외 처리
      final groupDoc = await FirebaseFirestore.instance.collection('groups').doc(targetGroupId).get();
      if (!groupDoc.exists) {
        // 상대방이 회원가입만 하고 아직 메인 화면에 접속하지 않은 상태이므로 내가 억지로 타인의 문서를 set() 하여
        // Security Rules 권한 오류(Permission Denied)를 내지 않고, 우아하게 SnackBar 안내 가이드를 제시하여 충돌을 회피합니다.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$targetName 님이 아직 앱 메인 지도를 켜지 않아 그룹이 미활성 상태입니다. 상대방이 앱을 최초 1회 실행한 후 다시 초대 코드를 등록해 주세요.'),
              backgroundColor: Colors.orangeAccent,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // 그룹이 안전하게 존재할 때만 내 UID를 추가 (보안 권한 보장)
      await FirebaseFirestore.instance.collection('groups').doc(targetGroupId).update({
        'members': FieldValue.arrayUnion([widget.user.uid])
      });

      await FirebaseFirestore.instance.collection('users').doc(widget.user.uid).update({
        'activeGroupId': targetGroupId,
        'groupId': targetGroupId,
      });

      if (mounted) {
        _inviteCodeController.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$targetName 님 그룹에 성공적으로 합류했어요!'),
            backgroundColor: Theme.of(context).colorScheme.secondary,
          ),
        );
      }
    } catch (e) {
      debugPrint('그룹 참여 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('참여 중 예기치 못한 에러가 발생했습니다: $e'),
            backgroundColor: tossRed,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isRegistering = false);
      }
    }
  }

  // 신규 그룹 생성 비즈니스 로직
  Future<void> _createGroup(String groupName) async {
    if (groupName.trim().isEmpty) return;
    
    setState(() => _isRegistering = true);
    try {
      final String newGroupId = FirebaseFirestore.instance.collection('groups').doc().id;
      final String code = _generateInviteCode();
      
      await FirebaseFirestore.instance.collection('groups').doc(newGroupId).set({
        'id': newGroupId,
        'name': groupName.trim(),
        'inviteCode': code,
        'members': [widget.user.uid],
        'createdBy': widget.user.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      await FirebaseFirestore.instance.collection('users').doc(widget.user.uid).update({
        'activeGroupId': newGroupId,
        'groupId': newGroupId,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('[$groupName] 그룹을 만들었어요!'),
            backgroundColor: Theme.of(context).colorScheme.secondary,
          ),
        );
      }
    } catch (e) {
      debugPrint('그룹 생성 실패: $e');
    } finally {
      if (mounted) {
        setState(() => _isRegistering = false);
      }
    }
  }

  // 그룹 나가기 비즈니스 로직
  Future<void> _leaveGroup(String groupId, String groupName) async {
    try {
      // 1. 그룹 멤버 목록에서 나 삭제
      await FirebaseFirestore.instance.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayRemove([widget.user.uid])
      });

      // 2. 다른 소속 그룹 찾기
      final myGroupsQuery = await FirebaseFirestore.instance
          .collection('groups')
          .where('members', arrayContains: widget.user.uid)
          .limit(1)
          .get();

      String nextGroupId;
      if (myGroupsQuery.docs.isNotEmpty) {
        nextGroupId = myGroupsQuery.docs.first.id;
      } else {
        // 소속된 다른 그룹이 없으면 기본 개인 그룹 자동 재생성
        nextGroupId = widget.user.uid;
        final String newCode = _generateInviteCode();
        await FirebaseFirestore.instance.collection('groups').doc(nextGroupId).set({
          'id': nextGroupId,
          'name': '기본 그룹',
          'inviteCode': newCode,
          'members': [widget.user.uid],
          'createdBy': widget.user.uid,
          'createdAt': FieldValue.serverTimestamp(),
        });
        await FirebaseFirestore.instance.collection('users').doc(widget.user.uid).update({
          'inviteCode': newCode,
        });
      }

      await FirebaseFirestore.instance.collection('users').doc(widget.user.uid).update({
        'activeGroupId': nextGroupId,
        'groupId': nextGroupId,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('[$groupName] 그룹에서 나왔습니다.')),
        );
      }
    } catch (e) {
      debugPrint('그룹 탈퇴 실패: $e');
    }
  }

  // 그룹 이름 변경 비즈니스 로직
  Future<void> _renameGroup(String groupId, String newName) async {
    if (newName.trim().isEmpty) return;
    try {
      await FirebaseFirestore.instance.collection('groups').doc(groupId).update({
        'name': newName.trim(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('그룹 이름을 변경했어요.')),
        );
      }
    } catch (e) {
      debugPrint('그룹 이름 변경 실패: $e');
    }
  }

  // 클립보드 복사 함수
  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('초대 코드가 클립보드에 복사되었습니다.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // 안심존 삭제 함수
  Future<void> _deleteSafeZone(Map<String, dynamic> zone) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({
        'safeZones': FieldValue.arrayRemove([zone])
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('안심존 [${zone['name']}]을(를) 삭제했습니다.'),
            backgroundColor: tossBlue,
          ),
        );
      }
    } catch (e) {
      debugPrint('안심존 삭제 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('안심존 삭제에 실패했습니다: $e'),
            backgroundColor: tossRed,
          ),
        );
      }
    }
  }

  // -----------------------------------------------------------------------------
  // 내 프로필 수정 기능 (닉네임 및 프로필 사진)
  // -----------------------------------------------------------------------------
  
  // 프로필 수정 바텀 시트 열기
  void _showProfileEditSheet() async {
    final String uid = widget.user.uid;
    final double safeBottom = MediaQuery.of(context).padding.bottom;
    
    // Firestore에서 실시간 최신 정보 가져오기
    DocumentSnapshot userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (!userDoc.exists) return;
    
    final userData = userDoc.data() as Map<String, dynamic>;
    String currentName = userData['name'] ?? '';
    String currentPhotoUrl = userData['photoUrl'] ?? '';
    
    final nameController = TextEditingController(text: currentName);
    String selectedPhotoUrl = currentPhotoUrl;
    bool isSaving = false;
    
    if (!mounted) return;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final bool hasPhoto = selectedPhotoUrl.isNotEmpty;
            
            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24 + safeBottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 시트 손잡이
                  Container(
                    width: 40,
                    height: 4.5,
                    decoration: BoxDecoration(
                      color: appleGray,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '내 프로필 수정',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: textPrimary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  // 프로필 사진 에디터 영역
                  GestureDetector(
                    onTap: () {
                      _showPhotoSourceSelection(
                        onPhotoSelected: (url) {
                          setModalState(() {
                            selectedPhotoUrl = url;
                          });
                        },
                      );
                    },
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: appleGray, width: 3),
                            color: tossBlue.withOpacity(0.1),
                            image: hasPhoto
                                ? DecorationImage(
                                    image: NetworkImage(selectedPhotoUrl),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: hasPhoto
                              ? null
                              : const Icon(
                                  Icons.person,
                                  size: 50,
                                  color: tossBlue,
                                ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                            color: tossBlue,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.camera_alt,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  // 닉네임 라벨 & 입력
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '닉네임',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    decoration: BoxDecoration(
                      color: appBg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: TextField(
                      controller: nameController,
                      maxLength: 10,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        counterText: '',
                        hintText: '이름을 입력해주세요 (2~10자)',
                        hintStyle: TextStyle(color: textSecondary),
                      ),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  
                  // 저장 버튼
                  isSaving
                      ? const Center(
                          child: CircularProgressIndicator(color: tossBlue),
                        )
                      : TossBounce(
                          onTap: () async {
                            final newName = nameController.text.trim();
                            if (newName.length < 2 || newName.length > 10) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('닉네임은 2자에서 10자 사이여야 합니다.'),
                                  backgroundColor: tossRed,
                                ),
                              );
                              return;
                            }
                            
                            setModalState(() {
                              isSaving = true;
                            });
                            
                            bool success = await _updateProfile(newName, selectedPhotoUrl);
                            
                            if (mounted) {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    success
                                        ? '프로필이 수정되었습니다.'
                                        : '프로필 수정에 실패했습니다.',
                                  ),
                                  backgroundColor: success ? tossBlue : tossRed,
                                ),
                              );
                            }
                          },
                          child: Container(
                            width: double.infinity,
                            height: 52,
                            decoration: BoxDecoration(
                              color: tossBlue,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Center(
                              child: Text(
                                '저장하기',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // 사진 수정 수단 선택 바텀시트
  void _showPhotoSourceSelection({required Function(String url) onPhotoSelected}) {
    final double safeBottom = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      backgroundColor: cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: EdgeInsets.only(
            top: 20,
            bottom: 20 + safeBottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined, color: tossBlue),
                title: const Text('갤러리에서 사진 선택', style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)),
                onTap: () async {
                  Navigator.pop(context);
                  String? uploadedUrl = await _pickAndUploadImage();
                  if (uploadedUrl != null) {
                    onPhotoSelected(uploadedUrl);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.face_outlined, color: tossBlue),
                title: const Text('프리셋 캐릭터 선택', style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)),
                onTap: () {
                  Navigator.pop(context);
                  _showPresetAvatarSelector(onPhotoSelected: onPhotoSelected);
                },
              ),
              ListTile(
                leading: const Icon(Icons.restart_alt, color: textSecondary),
                title: const Text('기본 이미지로 변경', style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)),
                onTap: () {
                  Navigator.pop(context);
                  onPhotoSelected('');
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // 프리셋 캐릭터 그리드 팝업
  void _showPresetAvatarSelector({required Function(String url) onPhotoSelected}) {
    final List<String> avatars = [
      'https://api.dicebear.com/7.x/adventurer/png?seed=Felix',
      'https://api.dicebear.com/7.x/adventurer/png?seed=Aneka',
      'https://api.dicebear.com/7.x/adventurer/png?seed=Lilou',
      'https://api.dicebear.com/7.x/adventurer/png?seed=Buster',
      'https://api.dicebear.com/7.x/adventurer/png?seed=Jack',
      'https://api.dicebear.com/7.x/adventurer/png?seed=Coco',
    ];
    
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text(
            '프리셋 캐릭터 아바타 선택',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: textPrimary),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: GridView.builder(
              shrinkWrap: true,
              itemCount: avatars.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemBuilder: (context, index) {
                final url = avatars[index];
                return GestureDetector(
                  onTap: () {
                    onPhotoSelected(url);
                    Navigator.pop(context);
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: appleGray, width: 2),
                      image: DecorationImage(
                        image: NetworkImage(url),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기', style: TextStyle(color: textSecondary, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  // 갤러리 이미지 피커 및 Firebase Storage 업로드
  Future<String?> _pickAndUploadImage() async {
    final picker = ImagePicker();
    try {
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 500,
        maxHeight: 500,
        imageQuality: 85,
      );
      
      if (image == null) return null;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('프로필 이미지를 업로드 중입니다...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      
      final File file = File(image.path);
      final String uid = widget.user.uid;
      
      // Firebase Storage 업로드 시작
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('profiles')
          .child('$uid.jpg');
          
      UploadTask uploadTask = storageRef.putFile(file);
      TaskSnapshot snapshot = await uploadTask;
      
      String downloadUrl = await snapshot.ref.getDownloadURL();
      return downloadUrl;
    } catch (e) {
      debugPrint('이미지 업로드 실패: $e');
      if (mounted) {
        String errorMsg = '이미지 선택 또는 업로드에 실패했습니다.';
        if (e.toString().contains('object-not-found') || e.toString().contains('bucket') || e.toString().contains('storage')) {
          errorMsg = 'Firebase Storage 서비스가 비활성화 상태입니다. 프리셋 아바타 캐릭터를 선택해 주세요.';
        } else {
          errorMsg = '$errorMsg ($e)';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMsg),
            backgroundColor: tossRed,
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return null;
    }
  }

  // Firestore 사용자 문서 업데이트
  Future<bool> _updateProfile(String name, String photoUrl) async {
    try {
      final String uid = widget.user.uid;
      
      // 1. Firestore 업데이트 (가장 중요하며, 앱 내 마커와 카드 표출에 사용됨)
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({
        'name': name,
        'photoUrl': photoUrl,
      });
      
      // 2. Firebase Auth 업데이트 (선택 사항이며, 실패해도 Firestore가 성공했으므로 진행)
      try {
        final currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser != null) {
          await currentUser.updateDisplayName(name);
          if (photoUrl.isNotEmpty) {
            await currentUser.updatePhotoURL(photoUrl);
          }
        }
      } catch (authError) {
        debugPrint('FirebaseAuth 로컬 프로필 업데이트 실패 (무시됨): $authError');
      }
      
      return true;
    } catch (e) {
      debugPrint('프로필 업데이트 실패: $e');
      return false;
    }
  }

  // 프로필 마커 위젯 빌드 (원형 사진 + 이름 배지)
  Widget _buildMarkerWidget(String name, String? photoUrl) {
    final String initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final bool hasPhoto = photoUrl != null && photoUrl.isNotEmpty;

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 원형 프로필 사진 (흰 테두리 + 파란 외곽선 + 그림자)
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.30),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
                color: tossBlue,
                image: hasPhoto
                    ? DecorationImage(
                        image: NetworkImage(photoUrl!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: hasPhoto
                  ? null
                  : Center(
                      child: Text(
                        initial,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
            ),
            // 삼각형 포인터
            CustomPaint(
              size: const Size(14, 7),
              painter: _TrianglePainter(color: tossBlue),
            ),
            // 이름 배지
            Container(
              constraints: const BoxConstraints(maxWidth: 90),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: tossBlue,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.20),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.none,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 프로필 마커 아이콘 생성 (이미지 선 로드 후 NOverlayImage 변환)
  Future<NOverlayImage?> _buildProfileMarkerIcon(String name, String? photoUrl) async {
    if (!mounted) return null;

    // 프로필 사진 선 로드 (NetworkImage 캐시 활용)
    if (photoUrl != null && photoUrl.isNotEmpty) {
      try {
        await precacheImage(NetworkImage(photoUrl), context);
      } catch (e) {
        debugPrint('프로필 이미지 선 로드 실패: $e');
      }
    }

    if (!mounted) return null;
    try {
      return await NOverlayImage.fromWidget(
        widget: _buildMarkerWidget(name, photoUrl),
        size: const Size(100, 96),
        context: context,
      );
    } catch (e) {
      debugPrint('마커 아이콘 생성 실패: $e');
      return null;
    }
  }

  // 지도 위에 오버레이(안심존 원형 구역 및 유저 마커) 업데이트
  Future<void> _updateMapOverlays(List<dynamic> safeZones, List<DocumentSnapshot> familyDocs) async {
    if (_mapController == null) return;
    if (_isUpdatingOverlays) return; // 이미 실행 중이면 건너뜀

    // [VETERAN TOUCH] 불필요한 무분별한 리사이징 Rebuild 시의 깜빡임(새로고침) 차단을 위한 데이터 지문 분석
    final String currentFingerprint = safeZones.map((z) => '${z['id']}_${z['latitude']}_${z['longitude']}').join('|') + 
        '#' + familyDocs.map((doc) {
          final data = doc.data() as Map<String, dynamic>? ?? {};
          return '${doc.id}_${data['latitude']}_${data['longitude']}_${data['status']}_${data['battery']}';
        }).join('|');

    if (_lastOverlayFingerprint == currentFingerprint) {
      return; // 데이터 변경이 없을 때는 오버레이 갱신을 생략하여 시각적 진동(깜빡임) 방지
    }
    _lastOverlayFingerprint = currentFingerprint;
    _isUpdatingOverlays = true;
    _mapController!.clearOverlays();

    // 1. 등록된 모든 안심존에 반경 100m 투명 원형 오버레이 그리기
    for (var zone in safeZones) {
      final circle = NCircleOverlay(
        id: zone['id'].toString(),
        center: NLatLng(zone['latitude'], zone['longitude']),
        radius: zone['radius'] ?? 100.0,
        color: tossBlue.withValues(alpha: 0.13),
        outlineColor: tossBlue,
        outlineWidth: 2,
      );
      _mapController!.addOverlay(circle);
    }

    // 2. 가족 구성원 실시간 위치 마커 (프로필 사진 마커)
    for (var doc in familyDocs) {
      final member = doc.data() as Map<String, dynamic>;
      final double? lat = member['latitude'];
      final double? lng = member['longitude'];
      final String name = member['name'] ?? '알 수 없음';
      final String? photoUrl = (member['photoUrl'] as String?)?.isNotEmpty == true
          ? member['photoUrl'] as String
          : null;

      if (lat != null && lng != null) {
        // 프로필 사진 마커 아이콘 생성
        final markerIcon = await _buildProfileMarkerIcon(name, photoUrl);

        // 생성자에 직접 전달 (addOverlay 이전에 setter 호출 불가)
        final marker = markerIcon != null
          ? NMarker(
              id: doc.id,
              position: NLatLng(lat, lng),
              icon: markerIcon,
              size: const Size(100, 96),
              anchor: const NPoint(0.5, 1.0),
            )
          : NMarker(
              id: doc.id,
              position: NLatLng(lat, lng),
              caption: NOverlayCaption(
                text: name, textSize: 13,
                color: tossBlue, haloColor: Colors.white,
              ),
            );

        _mapController!.addOverlay(marker);
      }
    }
    _isUpdatingOverlays = false; // guard 해제
  }


  // 내 위치로 지도 카메라 이동 및 줌 설정
  Future<void> _centerOnMyLocation() async {
    if (_mapController == null) return;
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      await _mapController!.updateCamera(
        NCameraUpdate.withParams(
          target: NLatLng(position.latitude, position.longitude),
          zoom: 15,
        ),
      );
    } catch (e) {
      debugPrint('내 위치 가져오기 실패: $e');
    }
  }

  void _showGroupSelector(List<DocumentSnapshot> myGroups, String activeGroupId) {
    final double safeBottom = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Container(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24 + safeBottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                '참여 중인 그룹 리스트',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '대화방을 바꾸는 것처럼 원하는 그룹을 선택하여\n가족과 친구들의 실시간 위치를 확인할 수 있어요.',
                style: TextStyle(fontSize: 12, color: textSecondary, height: 1.4),
              ),
              const Divider(height: 32, color: Colors.white10),
              
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: myGroups.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final groupDoc = myGroups[index];
                    final groupData = groupDoc.data() as Map<String, dynamic>;
                    final String groupId = groupDoc.id;
                    final String groupName = groupData['name'] ?? '그룹';
                    final List<dynamic> members = groupData['members'] ?? [];
                    final bool isActive = (groupId == activeGroupId);

                    return TossBounce(
                      onTap: () async {
                        Navigator.pop(context);
                        await FirebaseFirestore.instance
                            .collection('users')
                            .doc(widget.user.uid)
                            .update({
                              'activeGroupId': groupId,
                              'groupId': groupId,
                            });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: isActive ? tossBlue.withValues(alpha: 0.12) : appBg.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isActive ? tossBlue.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.05),
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    groupName,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                      color: isActive ? tossBlue : textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '참여 멤버 ${members.length}명 • 초대 코드: ${groupData['inviteCode'] ?? ''}',
                                    style: const TextStyle(fontSize: 11, color: textSecondary),
                                  ),
                                ],
                              ),
                            ),
                            Row(
                              children: [
                                if (isActive)
                                  const Icon(Icons.check_circle, color: tossBlue, size: 20)
                                else
                                  const SizedBox(width: 20),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(Icons.settings_outlined, color: textSecondary, size: 20),
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _showGroupSettings(groupId, groupName, groupData['inviteCode'] ?? '', groupData['createdBy'] ?? '');
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),
              
              Row(
                children: [
                  Expanded(
                    child: TossBounce(
                      onTap: () {
                        Navigator.pop(context);
                        _showCreateGroupDialog();
                      },
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: tossBlue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: tossBlue.withValues(alpha: 0.2)),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.add, color: tossBlue, size: 18),
                            SizedBox(width: 6),
                            Text(
                              '그룹 만들기',
                              style: TextStyle(color: tossBlue, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TossBounce(
                      onTap: () {
                        Navigator.pop(context);
                        _showJoinGroupDialog();
                      },
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: appleGray,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.vpn_key_outlined, color: Colors.white70, size: 16),
                            SizedBox(width: 6),
                            Text(
                              '코드로 참여',
                              style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _showCreateGroupDialog() {
    final TextEditingController controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('새 그룹 만들기', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('가족이나 친구들과 공유할 그룹의 이름을 지어주세요.', style: TextStyle(color: textSecondary, fontSize: 13)),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '예: 대학교 동창, 우리 가족',
                  hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  filled: true,
                  fillColor: appBg,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: textSecondary)),
            ),
            TossBounce(
              onTap: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  Navigator.pop(context);
                  _createGroup(name);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: tossBlue, borderRadius: BorderRadius.circular(12)),
                child: const Text('생성', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showJoinGroupDialog() {
    final TextEditingController controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('초대 코드로 그룹 참여', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('전달받은 6자리 초대 코드를 입력해 주세요.', style: TextStyle(color: textSecondary, fontSize: 13)),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: '예: TRX89P',
                  hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  filled: true,
                  fillColor: appBg,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: textSecondary)),
            ),
            TossBounce(
              onTap: () {
                final code = controller.text.trim().toUpperCase();
                if (code.isNotEmpty) {
                  Navigator.pop(context);
                  _joinGroupWithCode(code);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: tossBlue, borderRadius: BorderRadius.circular(12)),
                child: const Text('참여', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showGroupSettings(String groupId, String groupName, String inviteCode, String createdBy) {
    final double safeBottom = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Container(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 16,
            bottom: 16 + safeBottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '[$groupName] 설정',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textPrimary),
              ),
              const Divider(height: 32, color: Colors.white10),
              
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: appBg.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('그룹 초대 코드', style: TextStyle(fontSize: 11, color: textSecondary)),
                        const SizedBox(height: 2),
                        Text(
                          inviteCode,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: tossBlue, letterSpacing: 1.5),
                        ),
                      ],
                    ),
                    TossBounce(
                      onTap: () {
                        Navigator.pop(context);
                        _copyToClipboard(inviteCode);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(color: tossBlue, borderRadius: BorderRadius.circular(12)),
                        child: const Text('코드 복사', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              
              ListTile(
                leading: const Icon(Icons.edit_outlined, color: textPrimary),
                title: const Text('그룹 이름 변경', style: TextStyle(color: textPrimary, fontSize: 14)),
                onTap: () {
                  Navigator.pop(context);
                  _showRenameGroupDialog(groupId, groupName);
                },
              ),
              ListTile(
                leading: const Icon(Icons.exit_to_app_outlined, color: Colors.redAccent),
                title: const Text('그룹 나가기', style: TextStyle(color: Colors.redAccent, fontSize: 14)),
                onTap: () {
                  Navigator.pop(context);
                  _showLeaveConfirmDialog(groupId, groupName);
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showRenameGroupDialog(String groupId, String oldName) {
    final TextEditingController controller = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('그룹 이름 변경', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              filled: true,
              fillColor: appBg,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: textSecondary)),
            ),
            TossBounce(
              onTap: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  Navigator.pop(context);
                  _renameGroup(groupId, name);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: tossBlue, borderRadius: BorderRadius.circular(12)),
                child: const Text('변경', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showLeaveConfirmDialog(String groupId, String groupName) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('그룹 나가기', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.redAccent)),
          content: Text('정말 [$groupName] 그룹에서 나가시겠어요?\n그룹에서 나가면 더 이상 서로의 실시간 위치를 공유할 수 없습니다.', style: const TextStyle(color: textSecondary, fontSize: 13, height: 1.4)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: textSecondary)),
            ),
            TossBounce(
              onTap: () {
                Navigator.pop(context);
                _leaveGroup(groupId, groupName);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(12)),
                child: const Text('나가기', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ),
          ],
        );
      },
    );
  }

  // -----------------------------------------------------------------------------
  // 쌍방향 그룹 멤버 공유 중단 및 내보내기 로직
  // -----------------------------------------------------------------------------
  
  // 멤버 공유 중단 확인 다이얼로그
  void _showRemoveMemberConfirmDialog(String memberUid, String memberName, String groupId, String groupName) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('위치 공유 중단', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: tossRed)),
          content: Text(
            '정말 $memberName 님과의 실시간 위치 공유를 중단하시겠습니까?\n\n이 작업은 쌍방향으로 적용되어, 상대방도 회원님의 위치를 볼 수 없게 되며 그룹에서 완전히 제외됩니다.',
            style: const TextStyle(color: textSecondary, fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: textSecondary, fontWeight: FontWeight.bold)),
            ),
            TossBounce(
              onTap: () {
                Navigator.pop(context);
                _removeFamilyMemberFromGroup(memberUid, memberName, groupId);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: tossRed,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  '공유 중단',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // Firestore 그룹 및 멤버 문서에서 상대방 제외 처리
  Future<void> _removeFamilyMemberFromGroup(String memberUid, String memberName, String groupId) async {
    try {
      // 1. 그룹 문서의 members 배열 필드에서 제외 대상 uid 삭제
      await FirebaseFirestore.instance
          .collection('groups')
          .doc(groupId)
          .update({
        'members': FieldValue.arrayRemove([memberUid])
      });

      // 2. 제외 대상 멤버의 activeGroupId와 groupId가 내보내진 그룹과 같다면 개인 홈으로 리셋
      final memberDocRef = FirebaseFirestore.instance.collection('users').doc(memberUid);
      final memberSnapshot = await memberDocRef.get();
      
      if (memberSnapshot.exists && memberSnapshot.data() != null) {
        final data = memberSnapshot.data()!;
        final String currentActiveGroup = data['activeGroupId'] ?? '';
        
        if (currentActiveGroup == groupId) {
          await memberDocRef.update({
            'groupId': memberUid,
            'activeGroupId': memberUid,
          });
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$memberName 님과의 위치 공유가 해제되었습니다.'),
            backgroundColor: tossBlue,
          ),
        );
      }
    } catch (e) {
      debugPrint('멤버 내보내기 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('공유 중단 도중 에러가 발생했습니다: $e'),
            backgroundColor: tossRed,
          ),
        );
      }
    }
  }

  // 안심존 설정 패널 - 목록만 표시, 추가는 지도 위 플로팅 패널로
  void _showSafeZoneSettings(List<dynamic> safeZones) {
    final double safeBottom = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Container(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 16,
            bottom: 24 + safeBottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4.5,
                  decoration: BoxDecoration(color: appleGray, borderRadius: BorderRadius.circular(3)),
                ),
              ),
              const SizedBox(height: 20),
              const Text('안심존 관리하기',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textPrimary)),
              const SizedBox(height: 6),
              const Text('안심존 반경 100m 내에서는 배터리 절약을 위해 위치 수집을 멈춰요.',
                style: TextStyle(fontSize: 12, color: textSecondary, height: 1.4)),
              const Divider(height: 32, color: Color(0xFFE5E8EB)),

              if (safeZones.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24.0),
                  child: Center(
                    child: Text('등록된 안심존이 없습니다.\n아래 버튼으로 추가해보세요.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: textSecondary, fontSize: 13, height: 1.5)),
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: safeZones.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final zone = safeZones[index];
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(color: appBg, borderRadius: BorderRadius.circular(16)),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.home_work_outlined, color: tossBlue, size: 20),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(zone['name'] ?? '이름 없음',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textPrimary)),
                                  Text('반경 ${(zone['radius'] ?? 100).toInt()}m',
                                    style: const TextStyle(fontSize: 11, color: textSecondary)),
                                ],
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                            onPressed: () { _deleteSafeZone(zone); Navigator.pop(context); },
                          ),
                        ],
                      ),
                    );
                  },
                ),

              const SizedBox(height: 20),
              TossBounce(
                onTap: () async {
                  Navigator.pop(context);
                  await Future.delayed(const Duration(milliseconds: 300));
                  if (mounted) {
                    _showAddSafeZoneSheet();
                  }
                },
                child: Container(
                  width: double.infinity, height: 52,
                  decoration: BoxDecoration(color: tossBlue, borderRadius: BorderRadius.circular(16)),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_location_alt, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text('새로운 안심존 추가하기',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 15)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAddSafeZoneSheet() {
    final searchController = TextEditingController();
    final nameController = TextEditingController();
    final double safeBottom = MediaQuery.of(context).padding.bottom;
    Timer? debounceTimer;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        // 시트 전용 로컬 상태 (StatefulBuilder)
        List<dynamic> results = [];
        bool isSearching = false;
        double? selLat;
        double? selLng;
        String selAddress = '';

        return StatefulBuilder(
          builder: (ctx, setSheet) {

            Future<String> reverseGeocode(double lat, double lng) async {
              // 1. Android 네이티브 Geocoder 우선 호출
              if (!kIsWeb && Platform.isAndroid) {
                try {
                  final Map<dynamic, dynamic>? res = await _geocodingChannel.invokeMethod(
                    'reverseGeocode',
                    {'latitude': lat, 'longitude': lng},
                  );
                  if (res != null && res['formattedAddress'] != null) {
                    String addr = res['formattedAddress'] as String;
                    // "대한민국 " 접두사 정제
                    if (addr.startsWith('대한민국 ')) {
                      addr = addr.replaceFirst('대한민국 ', '');
                    }
                    return addr.trim();
                  }
                } catch (e) {
                  debugPrint('네이티브 역지오코딩 실패, Nominatim API로 폴백: $e');
                }
              }

              // 2. Fallback: Nominatim API
              try {
                final client = HttpClient();
                client.connectionTimeout = const Duration(seconds: 5);
                final url = Uri.parse(
                  'https://nominatim.openstreetmap.org/reverse'
                  '?lat=$lat&lon=$lng&format=json&accept-language=ko'
                );
                final req = await client.getUrl(url);
                req.headers.set(HttpHeaders.userAgentHeader, 'TheGuardianFamilySafetyApp/1.0 (basil@guardian.local)');
                final res = await req.close().timeout(const Duration(seconds: 5));
                if (res.statusCode == 200) {
                  final body = await res.transform(utf8.decoder).join();
                  final decoded = json.decode(body) as Map<String, dynamic>;
                  
                  final String fullAddr = decoded['display_name'] ?? '';
                  final parts = fullAddr.split(',');
                  if (parts.isNotEmpty) {
                    String addr = parts[0].trim();
                    if (addr.startsWith('대한민국 ')) {
                      addr = addr.replaceFirst('대한민국 ', '');
                    }
                    return addr;
                  }
                  return fullAddr;
                }
              } catch (e) {
                debugPrint('역지오코딩 오류: $e');
              }
              return '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
            }

            Future<void> doSearch(String q) async {
              String query = q.trim();
              if (query.isEmpty) {
                setSheet(() { results = []; });
                return;
              }

              // 도로명 주소 숫자가 띄어쓰기 없이 붙어있는 경우 자동 보정 (예: 여의대로56 -> 여의대로 56)
              final match = RegExp(r'^([가-힣a-zA-Z\s]+)(\d+)$').firstMatch(query);
              if (match != null) {
                query = '${match.group(1)!.trim()} ${match.group(2)}';
              }
              
              setSheet(() { isSearching = true; results = []; });

              // 1. Android 네이티브 Geocoder 우선 호출
              if (!kIsWeb && Platform.isAndroid) {
                try {
                  final List<dynamic>? res = await _geocodingChannel.invokeMethod(
                    'searchAddress',
                    {'address': query},
                  );
                  if (res != null && res.isNotEmpty) {
                    final List<dynamic> mappedResults = res.map((item) {
                      final data = item as Map<dynamic, dynamic>;
                      String rawAddr = (data['formattedAddress'] as String?) ?? '';
                      if (rawAddr.startsWith('대한민국 ')) {
                        rawAddr = rawAddr.replaceFirst('대한민국 ', '');
                      }
                      
                      final String postalCode = (data['postalCode'] as String?) ?? '';
                      final String postalText = postalCode.isNotEmpty ? ' [우편번호: $postalCode]' : '';
                      final String fullAddr = '$rawAddr$postalText';
                      
                      final parts = rawAddr.split(' ');
                      String shortName = rawAddr;
                      if (parts.length >= 2) {
                        shortName = '${parts[parts.length - 2]} ${parts[parts.length - 1]}';
                      }

                      return {
                        'display_name': fullAddr,
                        'lat': data['latitude'].toString(),
                        'lon': data['longitude'].toString(),
                      };
                    }).toList();

                    setSheet(() {
                      results = mappedResults;
                      isSearching = false;
                    });
                    return; // 성공 시 종료
                  }
                } catch (e) {
                  debugPrint('네이티브 지오코딩 실패, Nominatim API로 폴백: $e');
                }
              }

              // 2. Fallback: Nominatim API
              try {
                final client = HttpClient();
                client.connectionTimeout = const Duration(seconds: 10);
                
                final url = Uri.parse(
                  'https://nominatim.openstreetmap.org/search'
                  '?q=${Uri.encodeComponent(query)}'
                  '&format=json&limit=6&accept-language=ko&countrycodes=kr'
                );
                
                final req = await client.getUrl(url);
                req.headers.set(HttpHeaders.userAgentHeader, 'TheGuardianFamilySafetyApp/1.0 (basil@guardian.local)');
                final res = await req.close().timeout(const Duration(seconds: 10));
                
                if (res.statusCode == 200) {
                  final body = await res.transform(utf8.decoder).join();
                  final decoded = json.decode(body) as List<dynamic>;
                  setSheet(() => results = decoded);
                }
              } catch (e) {
                debugPrint('장소 검색 오류: $e');
              } finally {
                setSheet(() => isSearching = false);
              }
            }

            Future<void> selectCurrentLocation() async {
              setSheet(() { isSearching = true; });
              try {
                final status = await Permission.location.status;
                if (!status.isGranted) {
                  await Permission.location.request();
                }
                
                Position pos = await Geolocator.getCurrentPosition(
                  desiredAccuracy: LocationAccuracy.high,
                  timeLimit: const Duration(seconds: 4),
                );
                
                final addr = await reverseGeocode(pos.latitude, pos.longitude);
                setSheet(() {
                  selLat = pos.latitude;
                  selLng = pos.longitude;
                  selAddress = addr;
                  if (nameController.text.trim().isEmpty) {
                    nameController.text = '내 위치';
                  }
                });
              } catch (e) {
                debugPrint('Geolocator 실패, Firestore 백업 사용: $e');
                try {
                  final userDoc = await FirebaseFirestore.instance.collection('users').doc(widget.user.uid).get();
                  if (userDoc.exists && userDoc.data() != null) {
                    final data = userDoc.data()!;
                    final lat = data['latitude'] as double?;
                    final lng = data['longitude'] as double?;
                    if (lat != null && lng != null) {
                      final addr = await reverseGeocode(lat, lng);
                      setSheet(() {
                        selLat = lat;
                        selLng = lng;
                        selAddress = addr;
                        if (nameController.text.trim().isEmpty) {
                          nameController.text = '내 위치';
                        }
                      });
                      return;
                    }
                  }
                } catch (dbErr) {
                  debugPrint('Firestore 백업 읽기 실패: $dbErr');
                }
                
                if (ctx.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('현재 위치를 가져오지 못했습니다. 위치 권한을 확인해 주세요.')),
                  );
                }
              } finally {
                setSheet(() { isSearching = false; });
              }
            }

            Future<void> selectMapCenterLocation() async {
              if (_mapController == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('지도가 아직 준비되지 않았습니다.')),
                );
                return;
              }
              
              setSheet(() { isSearching = true; });
              try {
                final cameraPos = await _mapController!.getCameraPosition();
                final target = cameraPos.target;
                final addr = await reverseGeocode(target.latitude, target.longitude);
                setSheet(() {
                  selLat = target.latitude;
                  selLng = target.longitude;
                  selAddress = addr;
                  if (nameController.text.trim().isEmpty) {
                    nameController.text = '지도 선택 위치';
                  }
                });
              } catch (e) {
                debugPrint('지도 중심 설정 에러: $e');
              } finally {
                setSheet(() { isSearching = false; });
              }
            }

            Future<void> doRegister() async {
              final finalZoneName = nameController.text.trim();
              if (finalZoneName.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('안심존 이름을 입력해주세요')));
                return;
              }
              if (selLat == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('장소를 검색하고 선택해주세요')));
                return;
              }
              final zoneId = DateTime.now().millisecondsSinceEpoch.toString();
              try {
                await FirebaseFirestore.instance
                  .collection('users')
                  .doc(widget.user.uid)
                  .update({'safeZones': FieldValue.arrayUnion([{
                    'id': zoneId, 'name': finalZoneName,
                    'latitude': selLat, 'longitude': selLng, 'radius': 100.0,
                  }])});
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('안심존 [$finalZoneName] 추가 완료!'),
                    backgroundColor: tossBlue,
                  ));
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('저장 실패: $e'), backgroundColor: tossRed));
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: DraggableScrollableSheet(
                initialChildSize: 0.75,
                minChildSize: 0.5,
                maxChildSize: 0.95,
                expand: false,
                builder: (_, scrollController) => Column(
                  children: [
                    // 핸들 + 고정형 상단 헤더 & 검색창 (Pinned Top Header)
                    Container(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      decoration: const BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Center(child: Container(width: 40, height: 4,
                            decoration: BoxDecoration(color: appleGray, borderRadius: BorderRadius.circular(3)))),
                          const SizedBox(height: 16),
                          Row(children: [
                            Container(
                              width: 38, height: 38,
                              decoration: BoxDecoration(color: tossBlue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(11)),
                              child: const Icon(Icons.add_location_alt, color: tossBlue, size: 20),
                            ),
                            const SizedBox(width: 12),
                            const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('새 안심존 추가', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textPrimary)),
                                Text('장소를 설정하고 이름을 등록하세요', style: TextStyle(fontSize: 12, color: textSecondary)),
                              ],
                            ),
                          ]),
                          const SizedBox(height: 16),
                          
                          // 상단 고정 검색바 (Debounced Instant Autocomplete)
                          TextField(
                            controller: searchController,
                            onChanged: (val) {
                              if (debounceTimer?.isActive ?? false) debounceTimer!.cancel();
                              debounceTimer = Timer(const Duration(milliseconds: 400), () {
                                if (ctx.mounted) {
                                  if (val.trim().isNotEmpty) {
                                    doSearch(val);
                                  } else {
                                    setSheet(() { results = []; });
                                  }
                                }
                              });
                            },
                            onSubmitted: doSearch,
                            decoration: InputDecoration(
                              hintText: '주소 또는 장소명 검색 (예: 여의대로56)',
                              hintStyle: const TextStyle(color: textSecondary, fontSize: 13),
                              filled: true, fillColor: appBg,
                              prefixIcon: const Icon(Icons.search, color: tossBlue, size: 20),
                              suffixIcon: searchController.text.isNotEmpty 
                                ? IconButton(
                                    icon: const Icon(Icons.cancel, color: textSecondary, size: 18),
                                    onPressed: () {
                                      searchController.clear();
                                      setSheet(() { results = []; });
                                    },
                                  )
                                : null,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            ),
                          ),
                          const SizedBox(height: 10),
                          
                          // 상단 고정 2대 편의 퀵 단축 버튼
                          Row(
                            children: [
                              Expanded(
                                child: TossBounce(
                                  onTap: selectCurrentLocation,
                                  child: Container(
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: tossBlue.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.my_location, color: tossBlue, size: 14),
                                        SizedBox(width: 6),
                                        Text('현재 위치 지정', style: TextStyle(color: tossBlue, fontSize: 12, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TossBounce(
                                  onTap: selectMapCenterLocation,
                                  child: Container(
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: tossBlue.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.filter_center_focus, color: tossBlue, size: 14),
                                        SizedBox(width: 6),
                                        Text('지도 중심 지정', style: TextStyle(color: tossBlue, fontSize: 12, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          const Divider(color: appleGray, height: 1),
                        ],
                      ),
                    ),

                    // 스크롤 영역 (실시간 띄워질 미리보기 검색 리스트)
                    Expanded(
                      child: isSearching
                        ? const Center(child: CircularProgressIndicator(color: tossBlue))
                        : ListView(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                            children: [
                              if (results.isNotEmpty) ...[
                                ...results.map((r) {
                                  final name = (r['display_name'] as String?) ?? '';
                                  final shortName = name.split(',')[0].trim();
                                  final lat = double.tryParse(r['lat']?.toString() ?? '');
                                  final lon = double.tryParse(r['lon']?.toString() ?? '');
                                  final isSelected = selLat == lat && selLng == lon;
                                  return GestureDetector(
                                    onTap: () => setSheet(() {
                                      selLat = lat; selLng = lon; selAddress = name;
                                      if (nameController.text.trim().isEmpty) {
                                        nameController.text = shortName;
                                      }
                                      results = [];
                                      searchController.clear();
                                    }),
                                    child: Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                      decoration: BoxDecoration(
                                        color: isSelected ? tossBlue.withValues(alpha: 0.08) : appBg,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: isSelected ? tossBlue : Colors.transparent, width: 1.5),
                                      ),
                                      child: Row(children: [
                                        Icon(Icons.location_on_outlined,
                                          color: isSelected ? tossBlue : textSecondary, size: 18),
                                        const SizedBox(width: 12),
                                        Expanded(child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(shortName, style: TextStyle(
                                              fontWeight: FontWeight.w600, fontSize: 14,
                                              color: isSelected ? tossBlue : textPrimary)),
                                            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(fontSize: 11, color: textSecondary)),
                                          ],
                                        )),
                                        if (isSelected) const Icon(Icons.check_circle, color: tossBlue, size: 18),
                                      ]),
                                    ),
                                  );
                                }),
                              ] else if (searchController.text.trim().isNotEmpty) ...[
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 40.0),
                                  child: Center(
                                    child: Column(
                                      children: [
                                        Icon(Icons.search_off_rounded, color: textSecondary, size: 40),
                                        SizedBox(height: 12),
                                        Text('검색 결과가 없습니다.', style: TextStyle(color: textSecondary, fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                ),
                              ] else ...[
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 40.0),
                                  child: Center(
                                    child: Column(
                                      children: [
                                        Icon(Icons.map_outlined, color: tossBlue.withOpacity(0.3), size: 48),
                                        const SizedBox(height: 12),
                                        const Text(
                                          '위에서 장소를 검색하거나\n현재 위치 / 지도 중심 버튼을 눌러 지정해 보세요.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: textSecondary, fontSize: 13, height: 1.5),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                    ),

                    // 선택 완료 후 위젯 하단 슬라이딩 고정 카드 (Guided Slide-Up Footer)
                    if (selLat != null)
                      Container(
                        padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + safeBottom),
                        decoration: BoxDecoration(
                          color: cardBg,
                          border: Border(top: BorderSide(color: appleGray.withOpacity(0.5), width: 1)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.04),
                              blurRadius: 10,
                              offset: const Offset(0, -4),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: tossBlue.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.check_circle_rounded, color: tossBlue, size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '선택된 장소: ${selAddress.split(',')[0]}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: tossBlue),
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () => setSheet(() { selLat = null; selLng = null; selAddress = ''; nameController.clear(); }),
                                    child: const Text('초기화', style: TextStyle(color: tossRed, fontSize: 12, fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text('안심존 이름 지정', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textSecondary)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: nameController,
                              onChanged: (val) {
                                setSheet(() {});
                              },
                              decoration: InputDecoration(
                                hintText: '예: 집, 회사, 학교',
                                hintStyle: const TextStyle(color: textSecondary, fontSize: 13),
                                filled: true, fillColor: appBg,
                                prefixIcon: const Icon(Icons.label_outline, color: tossBlue, size: 18),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              ),
                            ),
                            const SizedBox(height: 14),
                            TossBounce(
                              onTap: doRegister,
                              child: Container(
                                width: double.infinity, height: 50,
                                decoration: BoxDecoration(
                                  color: nameController.text.trim().isNotEmpty ? tossBlue : appleGray,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Center(child: Text(
                                  '이 위치에 안심존 등록하기',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 14,
                                    color: nameController.text.trim().isNotEmpty ? Colors.white : textSecondary,
                                  ),
                                )),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      debounceTimer?.cancel();
    });
  }

  Widget _buildBatteryBadge(int batteryLevel) {
    IconData iconData;
    Color color;

    if (batteryLevel >= 85) {
      iconData = Icons.battery_full;
      color = const Color(0xFF2DFF9A);
    } else if (batteryLevel >= 40) {
      iconData = Icons.battery_3_bar;
      color = const Color(0xFFF59E0B);
    } else {
      iconData = Icons.battery_alert;
      color = Colors.redAccent;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconData, color: color, size: 14),
          const SizedBox(width: 4),
          Text(
            '$batteryLevel%',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String currentUserId = widget.user.uid;

    return StreamBuilder<DocumentSnapshot>(
      stream: _userStream,
      builder: (context, userSnapshot) {
        if (userSnapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: tossBlue),
            ),
          );
        }
        if (!userSnapshot.hasData || userSnapshot.data?.data() == null) {
          return const Scaffold(
            body: Center(
              child: Text('프로필을 가져오지 못했어요.'),
            ),
          );
        }

        final myData = userSnapshot.data!.data() as Map<String, dynamic>;
        String myInviteCode = myData['inviteCode'] ?? '';
        String myGroupId = myData['groupId'] ?? '';
        String activeGroupId = myData['activeGroupId'] ?? '';
        final List<dynamic> safeZones = myData['safeZones'] ?? [];

        // 초대 코드가 없는 기존 사용자의 경우 자동으로 생성하여 Firestore에 업데이트합니다.
        if (myInviteCode.isEmpty) {
          final String newCode = _generateInviteCode();
          myInviteCode = newCode;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            FirebaseFirestore.instance
                .collection('users')
                .doc(currentUserId)
                .update({'inviteCode': newCode});
          });
        }

        // 그룹 ID가 누락된 경우 자신의 UID로 자동 초기화합니다.
        if (myGroupId.isEmpty) {
          myGroupId = currentUserId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            FirebaseFirestore.instance
                .collection('users')
                .doc(currentUserId)
                .update({'groupId': currentUserId});
          });
        }

        // 활성 그룹 ID가 누락된 경우 기본 그룹 ID로 설정합니다.
        if (activeGroupId.isEmpty) {
          activeGroupId = myGroupId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            FirebaseFirestore.instance
                .collection('users')
                .doc(currentUserId)
                .update({'activeGroupId': myGroupId});
          });
        }

        final activeGroupDocRef = FirebaseFirestore.instance.collection('groups').doc(activeGroupId);

        if (activeGroupId != _lastActiveGroupId || _activeGroupStream == null) {
          _lastActiveGroupId = activeGroupId;
          _activeGroupStream = activeGroupDocRef.snapshots();
        }

        return StreamBuilder<DocumentSnapshot>(
          stream: _activeGroupStream,
          builder: (context, groupSnapshot) {
            if (groupSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(color: tossBlue),
                ),
              );
            }

            // 활성 그룹 문서가 존재하지 않는 경우, 마이그레이션(자동 생성) 실행
            if (!groupSnapshot.hasData || !groupSnapshot.data!.exists) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                activeGroupDocRef.set({
                  'id': activeGroupId,
                  'name': '기본 그룹',
                  'inviteCode': myInviteCode,
                  'members': [currentUserId],
                  'createdBy': currentUserId,
                  'createdAt': FieldValue.serverTimestamp(),
                }, SetOptions(merge: true));
              });
              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(color: tossBlue),
                ),
              );
            }

            final groupData = groupSnapshot.data!.data() as Map<String, dynamic>;
            final List<dynamic> members = groupData['members'] ?? [currentUserId];

            final List<String> familyUids = members
                .map((m) => m.toString())
                .where((uid) => uid != currentUserId)
                .toList();

            // 가입 그룹 전체 목록 스트림
            return StreamBuilder<QuerySnapshot>(
              stream: _myGroupsStream,
              builder: (context, myGroupsSnapshot) {
                final List<DocumentSnapshot> myGroups = myGroupsSnapshot.hasData ? myGroupsSnapshot.data!.docs : [];

                if (familyUids.isEmpty) {
                  return _buildHomeScreenContent(
                    myData: myData,
                    activeGroupId: activeGroupId,
                    groupData: groupData,
                    familyDocs: [],
                    myGroups: myGroups,
                    safeZones: safeZones,
                    currentUserId: currentUserId,
                  );
                }

                // 가족 멤버 목록 스트림 캐싱 로직
                final String currentFamilyFingerprint = familyUids.join(',');
                if (currentFamilyFingerprint != _lastFamilyUidsFingerprint || _membersStream == null) {
                  _lastFamilyUidsFingerprint = currentFamilyFingerprint;
                  _membersStream = FirebaseFirestore.instance
                      .collection('users')
                      .where(FieldPath.documentId, whereIn: familyUids)
                      .snapshots();
                }

                // 가족 멤버 목록 스트림
                return StreamBuilder<QuerySnapshot>(
                  stream: _membersStream,
                  builder: (context, membersSnapshot) {
                    final List<DocumentSnapshot> familyDocs = membersSnapshot.hasData ? membersSnapshot.data!.docs : [];
                    
                    // 지도에 실시간으로 오버레이 그려주기 (빌드 완료 후 실행)
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _updateMapOverlays(safeZones, familyDocs);
                    });

                    return _buildHomeScreenContent(
                      myData: myData,
                      activeGroupId: activeGroupId,
                      groupData: groupData,
                      familyDocs: familyDocs,
                      myGroups: myGroups,
                      safeZones: safeZones,
                      currentUserId: currentUserId,
                    );
                  }
                );
              }
            );
          }
        );
      },
    );
  }

  // 홈 화면 컨텐츠 빌드
  Widget _buildHomeScreenContent({
    required Map<String, dynamic> myData,
    required String activeGroupId,
    required Map<String, dynamic> groupData,
    required List<DocumentSnapshot> familyDocs,
    required List<DocumentSnapshot> myGroups,
    required List<dynamic> safeZones,
    required String currentUserId,
  }) {
    final String groupName = groupData['name'] ?? '기본 그룹';
    final String groupInviteCode = groupData['inviteCode'] ?? '';

    return Scaffold(
      appBar: AppBar(
        title: TossBounce(
          onTap: () => _showGroupSelector(myGroups, activeGroupId),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                groupName,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down, size: 20, color: textSecondary),
            ],
          ),
        ),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TossBounce(
            onTap: () => _showProfileEditSheet(),
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: tossBlue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Text(
                  '내 프로필',
                  style: TextStyle(
                    color: tossBlue,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TossBounce(
            onTap: () async {
              FlutterBackgroundService().invoke('stopService');
              await GoogleSignIn.instance.signOut();
              await FirebaseAuth.instance.signOut();
            },
            child: Container(
              margin: const EdgeInsets.only(right: 16, top: 12, bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Text(
                  '로그아웃',
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. 그룹 초대 카드 정보
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: tossBlue.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(Icons.group_outlined, size: 24, color: tossBlue),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              groupName,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              '이 그룹에 가족과 친구들을 초대해 보세요.',
                              style: TextStyle(
                                fontSize: 12,
                                color: textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: appBg.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '그룹 참여용 초대 코드',
                              style: TextStyle(fontSize: 11, color: textSecondary),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              groupInviteCode,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 2.0,
                                color: tossBlue,
                              ),
                            ),
                          ],
                        ),
                        TossBounce(
                          onTap: () => _copyToClipboard(groupInviteCode),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: tossBlue,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              '복사하기',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 2. 함께 위치를 공유하는 사람들 목록
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '함께 위치 나누는 멤버',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textPrimary),
                ),
                TossBounce(
                  onTap: () => _showSafeZoneSettings(safeZones),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: tossBlue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '🏡 안심존 관리',
                      style: TextStyle(color: tossBlue, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            if (familyDocs.isNotEmpty)
              SizedBox(
                height: 96,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: familyDocs.length,
                  separatorBuilder: (context, index) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final memberData = familyDocs[index].data() as Map<String, dynamic>;
                    final String name = memberData['name'] ?? '가족';
                    final String photoUrl = memberData['photoUrl'] ?? '';
                    final int battery = memberData['battery'] ?? 100;
                    final double? lat = memberData['latitude'];
                    final double? lng = memberData['longitude'];

                    return TossBounce(
                      onTap: () {
                        if (lat != null && lng != null && _mapController != null) {
                          _mapController!.updateCamera(
                            NCameraUpdate.withParams(
                              target: NLatLng(lat, lng),
                              zoom: 15,
                            ),
                          );
                        }
                      },
                      child: Container(
                        width: 180,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.04),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundImage: photoUrl != '' ? NetworkImage(photoUrl) : null,
                            child: photoUrl == '' ? const Icon(Icons.person, size: 18) : null,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                                const SizedBox(height: 4),
                                _buildBatteryBadge(battery),
                              ],
                            ),
                          ),
                          // 쌍방향 공유 중단 (멤버 내보내기/삭제) 버튼 추가
                          GestureDetector(
                            onTap: () {
                              _showRemoveMemberConfirmDialog(
                                familyDocs[index].id,
                                name,
                                activeGroupId,
                                groupName,
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4, right: 2),
                              child: Icon(
                                Icons.cancel_rounded,
                                color: tossRed.withValues(alpha: 0.8),
                                size: 18,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: TextField(
                        controller: _inviteCodeController,
                        textCapitalization: TextCapitalization.characters,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: '그룹 또는 가족의 초대 코드 6자리 입력',
                          hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                          filled: true,
                          fillColor: cardBg,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: tossBlue, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TossBounce(
                    onTap: _isRegistering ? null : () => _joinGroupWithCode(_inviteCodeController.text),
                    child: Container(
                      height: 48,
                      width: 72,
                      decoration: BoxDecoration(
                        color: tossBlue,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Center(
                        child: _isRegistering
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('등록', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            
            const SizedBox(height: 16),

            // 3. 네이버 지도 영역
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Container(
                  color: cardBg,
                  child: Stack(
                    children: [
                      if (kIsWeb)
                        Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.map_outlined, color: textSecondary, size: 48),
                              const SizedBox(height: 12),
                              const Text(
                                '지도는 모바일 기기(Android/iOS) 전용입니다.',
                                style: TextStyle(color: textSecondary, fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 6),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                                child: Text(
                                  '웹 버전에서는 지도 시각화가 제한되지만, 가족 등록 및 실시간 위치/배터리 정보 연동은 정상 동작합니다.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: textSecondary.withValues(alpha: 0.6), fontSize: 11, height: 1.4),
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        NaverMap(
                          options: const NaverMapViewOptions(
                            indoorEnable: true,
                            locationButtonEnable: false, // 커스텀 버튼 사용을 위해 false로 설정
                            consumeSymbolTapEvents: false,
                          ),
                          onMapReady: (controller) async {
                            _mapController = controller;
                            
                            // 권한 확인 후 위치 추적 모드를 활성화하여 내 위치 파란색 점 표시 및 follow 모드 진입
                            final hasPermission = await Permission.location.isGranted;
                            if (hasPermission) {
                              controller.setLocationTrackingMode(NLocationTrackingMode.follow);
                            }
                            
                            _updateMapOverlays(safeZones, familyDocs);
                          },
                        ),
                      
                      // 내 위치로 카메라 정렬하는 플로팅 버튼 (Toss Style)
                      if (!kIsWeb)
                        Positioned(
                          bottom: 16,
                          right: 16,
                          child: TossBounce(
                            onTap: _centerOnMyLocation,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: cardBg,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    blurRadius: 8,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.my_location,
                                color: tossBlue,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: 16 + MediaQuery.of(context).padding.bottom),
          ],
        ),
      ),
    );
  }
}
// 마커 삼각형 포인터 CustomPainter
class _TrianglePainter extends CustomPainter {
  final Color color;
  const _TrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
