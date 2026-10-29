# 실현 가능성 조사 — 2026-10-29

> 이 문서는 초기 장비 조합을 조사한 기록이다. 아래 프린터 모델과 연결 메뉴는 당시 조사 대상의 예시이며, 현재 앱의 프린터 제한이 아니다. 현재 인쇄는 제조사와 무관한 AirPrint를 사용한다. 최신 사용법과 지원 범위는 [README](../README.md)를 따른다.

## 판정

**iPad 단독 실행 구조는 구현할 근거가 있다. A7 IV에서 USB 촬영 후 JPEG를 안정적으로 받는지는 아직 실증하지 못했다.**
이번 결과는 실험용 드라이버와 실제 Xcode 프로젝트이며 행사에 바로 투입할 검증 완료 제품이 아니다.
연결 API의 존재, 공개 구현의 지원 목록, 모의 시험 통과를 실기기 성공으로 바꾸어 말하지 않는다.

| 항목 | 확인한 사실 | 남은 검증 |
| --- | --- | --- |
| USB 접근 | API와 공개 구현 외에도 실제 iPad의 ImageCaptureCore PTP 이벤트 전달을 크래시 기록에서 확인함 | 수정 후 안정적인 연결·이벤트 처리 반복 |
| Sony 직접 제어 | Sony 공식 지원 목록에 ILCE-7M4가 있으며 환경 독립적인 PTP 경로를 제공함 | 현 펌웨어의 V3 협상·지원 속성·S1/S2 동작 |
| JPEG 수신 | libgphoto2에 Sony의 D215 준비 상태 확인 → GetObjectInfo/GetObject 경로가 있음 | iPad의 ImageCaptureCore가 동일 경로로 전체 JPEG를 전달하는지, 10초 주기 처리량 |
| CP1500 | Canon 공식 설명서에 직접 Wi-Fi와 AirPrint가 각각 명시됨 | Other/Direct Connection 모드의 Bonjour 탐색·용지·재단·실제 출력 |
| 무료 운영 | 외부 패키지·유료 API·서버 없는 앱을 작성함 | 무료 개발 서명은 7일마다 갱신 필요, 영구 무정비 무료 배포 보장 불가 |

## 조사한 구현과 선택

1. [Apple ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser),
   [requestSendPTPCommand](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand(_:outdata:completion:)).
   SDK 헤더도 직접 읽었다. 단순 USB 파일 가져오기만으로는 Sony의 원격 촬영 경로가 완성되지 않아,
   공개 PTP pass-through 위에 Sony 명령을 직렬로 보낸다. iPad 앱에서 일반 libusb 접근을 가정하지 않는다.
   iPad의 실제 크래시에서 PTP 이벤트가 ICDeviceOperationQueue에서 전달됨을 확인했다.
   PTP 이벤트 수신은 nonisolated로 받고 앱 상태 변경만 MainActor로 넘긴다. PTP completion도
   명시적인 Sendable 콜백으로 받아 MainActor로 넘긴다. 세션 delegate와 이벤트 delegate의 큐 보장을 구분한다.

2. [Sony Camera Remote Command](https://support.d-imaging.sony.co.jp/app/cameraremotecommand/en/index.html).
   고수준 Camera Remote SDK 바이너리를 iPad에서 쓸 수 있다고 가정하지 않았다. PTP 프로토콜 경로를 선택했다.
   공식 페이지는 자료가 무료라고 안내하지만 개인에게는 다운로드를 제공하지 않으며 기업 고객을 대상으로 한다.
   한국은 지역 담당 연락 경로를 안내한다. 본 세션에서는 공식 명령 자료 ZIP을 받거나 사용권에 동의하지 않았다.
   따라서 모델별 명령표 전체를 공식 문서와 대조한 상태는 아니다. PTP2에 대한 장래 제한 안내도 있어 V3만 시도한다.

3. [CrCmd.DPCC.ios, c46fc57](https://github.com/sohtamei/CrCmd.DPCC.ios/tree/c46fc57b45233421c4d95ee358ae067b7d0285dc).
   Apache-2.0 소스다. CameraManager.swift에서 ImageCaptureCore → V3 연결 → S1/S2 촬영과
   라이브뷰 수신을 확인했다. **촬영 JPEG 다운로드는 없으며 setupCamera는 저장 대상을 카메라로 설정한다.**
   또한 응답 컨테이너 파싱 성공을 명령 성공으로 처리하는 곳이 있어 PTP 응답 코드 판정을 새로 작성했다.
   바이너리 범위 검사·직렬화·중단 복구·세션 저장도 독립적으로 구현했다.

4. [libgphoto2 Sony 촬영 구현](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/library.c),
   [PTP V3 협상](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptp.c),
   [속성 해석](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptp-pack.c),
   [카메라 저장 위치 값](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/config.c).
   프로토콜 사실을 교차 확인했다. D215가 준비됐다고 말하기 전에 가상 핸들을 읽으면 일부 카메라가
   오작동할 수 있다는 구현상 주의가 있어 준비 확인을 강제했다. libgphoto2는 앱에 복사·링크하지 않는다.
   카메라 카드와 호스트 양쪽 저장(0x11)을 요구하며 과거 RAM 사진을 자동 폐기하거나 새 촬영으로 인정하지 않는다.

5. [Sony A7 IV 원격 저장 설정](https://helpguide.sony.net/ilc/2110/v1/en/contents/TP1000659438.html).
   앱은 단일 촬영·JPEG 전용·카드와 호스트 양쪽 저장·Original 전송으로 범위를 좁힌다.
   MF 필수 조건은 사용자 요청으로 제거했다. AF에서는 반셔터 후 D213의 초점 상태(2/6)를 확인하고
   카운트다운 시각에 본 셔터를 누른다. 0.1.4부터 제한 시간 내 초점 미확인 또는 D213 누락도 본 셔터 명령을 막지 않는다. 실제 셔터 동작은 카메라의 AF 우선순위 설정에도 영향을 받는다.
   사용자가 수정 후 촬영 동작을 확인했다. RAW/HEIF 변환·영상·버스트는 범위 밖이다.
   0.1.2에서 같은 참고 구현의 `GetObject(0xFFFFC002)`와 헤더의 JPEG offset/size로 라이브뷰를 추가했다.
   라이브뷰와 촬영 명령을 별도 루프로 동시에 보내지 않고 촬영 대기·AF 대기 안에서 직렬로 처리한다.
   범위가 잘린 프레임·JPEG 손상·지속적인 DeviceBusy·취소·원본 수신 중 프레임 요청 금지를 시험한다.
   실제 A7 IV의 라이브뷰는 사용자 장비에서 추가 확인해야 한다.
   0.1.2의 기기용 서명 빌드와 시뮬레이터 빌드가 통과했다. 16개 핵심 시험(17개 실행 사례),
   백그라운드 delegate 회귀 검사와 iPad 시뮬레이터 가로·세로 데모 화면 확인을 수행했다.
   시뮬레이터의 ImageCaptureCore 권한 메서드가 구현되지 않아 발생하는 예외는 플랫폼 분기로 방지한다.
   이후 사용자가 라이브뷰 JPEG 경계 오류를 보고했다. libgphoto2의 Sony preview 경로는 헤더 offset을
   우선한 뒤 JPEG 시작·끝을 추출하며 영역 끝이 JPEG 끝이라고 가정하지 않는 것을 확인했다.
   0.1.3은 선언된 이미지 범위 안의 JPEG 세그먼트를 따라 완전한 JPEG만 추출한다. 실제 생성한 JPEG
   fixture로 앞뒤 패딩, 헤더 앞의 가짜 SOI, COM 내부 중첩 표식과 잘린 파일을 검사했다.
   18개 시험(19개 실행 사례)과 기기용 서명 빌드가 통과했다. 사용자 카메라에서의 재확인은 필요하다.
   GUI 카메라 설정을 무단 변경하지 않고 가능한 설정은 읽어 검사한다. 단일 촬영/JPEG 설정은 운영자가
   카메라에서 확인하고 첫 JPEG 검증으로 전송 형식까지 확인해야 한다.

6. [Canon 직접 연결](https://cam.start.canon/en/P001/manual/html/UG-03_Print_Wi-Fi_0020.html),
   [Canon AirPrint](https://cam.start.canon/en/P001/manual/html/UG-03_Print_Wi-Fi_0030.html),
   [Apple UIPrintInteractionController](https://developer.apple.com/documentation/uikit/uiprintinteractioncontroller).
   설정 단계에서 운영자가 iPad를 CP1500 SSID에 연결한다. USB 카메라는 Wi-Fi를 점유하지 않는다.
   앱에서는 네이티브 인쇄 시트를 띄운다. 자체 인쇄 프로토콜·Canon 앱 전환·자동 Wi-Fi 설정 기능을 만들지 않는다.
   iPadOS 인쇄 완료 콜백을 물리적 종이 출력 확인으로 해석하지 않는다. 실제 작업 상태는 Print Center나 프린터에서 확인한다.

7. [Apple 무료 계정](https://developer.apple.com/help/account/basics/about-your-developer-account).
   무료 개인 개발 서명의 만료 제한 때문에 모든 조건을 영구히 동시에 충족하는 배포 방식을 약속하지 않는다.
   Mac은 개발·서명·설치에 필요하다. 설치된 앱의 촬영·합성·인쇄 운영에는 Mac이나 서버가 필요 없도록 구현했다.

## 현재 구현의 검증 경계

- 통과: BoothCore 빌드와 핵심 규칙 검사 8개, macOS ImageCaptureCore 헤더 기준 USBTransport Swift 6 타입 검사,
  앱 Swift 파일 구문 검사, 프로젝트·Info.plist·privacy manifest 파싱과 참조 파일 존재 확인.
  이후 Xcode 26.3 설치 상태에서 Swift Testing으로 8개 시험이 통과했으며, iOS Simulator 26.2 SDK를 대상으로
  BoothCore 모듈 생성 및 앱 전체의 Swift 6/MainActor 타입 검사가 통과했다.
  기기용 전체 빌드에서는 Swift 6.2.4가 Binding setter의 메서드 참조를 코드 생성하다 내부 오류로 종료됐다.
  명시적 클로저로 변경한 후 서명 없는 기기용 xcodebuild에서 컴파일·링크·패키징이 모두 통과했다.
  iPad의 촬영 중 크래시 2건은 ICDeviceOperationQueue에서 `USBTransport.cameraDevice(_:didReceivePTPEvent:)`의
  MainActor 실행기 검사가 실패한 동일 원인이었다. 이벤트를 nonisolated로 수신하도록 수정하고
  실제 delegate를 백그라운드에서 호출하는 macOS 재현 검사가 통과했다. AF 변경 후 Swift Testing
  11개 시험(초점 성공의 2개 사례 포함)과 서명을 포함한 기기용 빌드도 통과했다.
- 미실행: SwiftUI 실제 렌더링·터치/VoiceOver, USB 실물 제어,
  JPEG 전송 8장/연속 세션, AirPrint 발견·실제 인쇄·장애 복구.
- 초기 조사 시 호스트에는 Command Line Tools만 있어 portable runner로 시험했다. 이후 사용자가 Xcode 26.3과
  SDK를 설치했다. 초기에는 플랫폼 다운로드 중이라 실행 대상을 찾지 못했지만, 다운로드 이후
  기기용 빌드가 통과했고 iPad Pro M4도 감지됐다. 서명 없는 빌드 통과를 iPad 설치·실행이나 장비 검증 성공으로 해석하지 않는다.

소프트웨어가 10초 간격을 예약하더라도 iPadOS 스케줄링·USB 왕복·카메라 셔터 지연은 하드 실시간이 아니다.
타임아웃과 수신 지연은 중단 사유이며, 행사 전 실제 셔터 간격을 측정해야 한다.

## 다음 검증 순서

화면 취향 조정보다 먼저 [장비 검증 절차](hardware-validation.md)의 USB 한 장·JPEG 수신·8장 반복을 통과시킨다.
V3 속성 레이아웃이 다르거나 호스트 JPEG가 오지 않으면 해당 펌웨어의 공식 명령표·USB trace를 확보하고
드라이버를 수정해야 한다. 이때 데모 데이터나 일반 사진 가져오기를 USB 제어 성공의 대체 증거로 사용하지 않는다.
