# 참고 구현과 고지

Sony PTP-V3 연결·S1/S2 제어·속성 레이아웃 조사에는
[sohtamei/CrCmd.DPCC.ios](https://github.com/sohtamei/CrCmd.DPCC.ios/tree/c46fc57b45233421c4d95ee358ae067b7d0285dc)를 참고했다.
원 저장소의 Apache-2.0 라이선스 사본은 이 폴더에 있다. 원 프로젝트 이름, 로고, UI, 계정/서명 설정은 가져오지 않았다.
이 프로젝트의 구현은 2026-10-29에 새로 작성·변경했다. USB 어댑터·바이너리 파서는 원본과 다르게
응답 코드 확인, 경계 검사, 직렬화, 타임아웃, 미확인 촬영 복구를 수행한다.

[libgphoto2](https://github.com/gphoto/libgphoto2)의 Sony 구현은 D215 준비 상태와 0xFFFFC001 전송 흐름의
독립적인 프로토콜 근거로 조사했다. libgphoto2 코드·바이너리를 복사하거나 링크하지 않았다.
LGPL 라이브러리를 iPad 앱에 포함하는 방식은 사용하지 않았다.

Sony Camera Remote Command 명령 자료·SDK·예제 ZIP은 포함하지 않는다.
Sony의 공식 자료 이용·재배포 권한이 필요하면 Sony의 지역별 제공 조건과 사용권을 별도로 확인한다.
Apple·Sony·Canon의 제품명은 장비 식별을 위해 사용한다.
