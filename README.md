# RemoteForMac

아이폰을 Mac의 리모컨으로 사용하는 오픈소스 프로젝트입니다. Mac에서 **RemoteForMac Host**를 실행하고, 같은 Wi-Fi의 아이폰에서 **iPhone 앱** 또는 **Safari 웹 리모컨**으로 연결합니다. 외부 모니터에 연결한 Mac을 멀리서 조작할 때 사용할 수 있습니다.

> 이 저장소는 **소스 코드**를 제공합니다. Mac용 실행 파일이나 App Store에 설치할 수 있는 iPhone 앱을 제공하는 것은 아닙니다. 아래 안내에 따라 직접 빌드할 수 있습니다.

## 할 수 있는 일

- 터치패드에서 커서 이동, 탭/더블클릭, 오른쪽 클릭, 두 손가락 스크롤과 확대·축소, 드래그
- 세 손가락 드래그, 네 손가락 데스크톱 전환·Mission Control·데스크톱 보기
- Mac의 입력창을 선택한 뒤 아이폰 키보드로 입력, 방향키·Esc, 스크롤 방향 선택
- YouTube 웹 앱과 Safari의 Netflix 창 열기
- 여러 아이폰/Mac 등록, 등록된 기기 다시 연결
- Mac이 제공하는 웹 리모컨을 아이폰 홈 화면에 추가해 사용

일부 제스처는 Mac 단축키나 앱의 확대 기능으로 구현됩니다. 모든 macOS 트랙패드 기능을 그대로 복제하지는 않습니다. 비밀번호·보안 입력란은 원격 키보드 입력 대상에서 제외됩니다. Mac 앱이 실행 중이고 두 기기가 같은 로컬 네트워크에 있어야 합니다.

## 필요한 환경

- Mac: macOS 14 이상, Xcode가 설치된 개발 환경
- 네이티브 iPhone 앱: iOS 17 이상, Xcode에서 앱을 직접 설치할 본인 Apple 계정
- 웹 리모컨: 아이폰 Safari. iPhone 앱 설치와 개발자 모드는 필요하지 않음

## 설치 및 사용

### 1. Mac 앱 빌드

1. 이 저장소를 내려받아 `RemoteTV.xcodeproj`를 Xcode에서 엽니다.
2. 상단 scheme에서 `RemoteTVHost`, 실행 기기에서 `My Mac`을 선택합니다. `RemoteTVHost` target → **Signing & Capabilities**에서 본인의 Team을 선택하고 **Run**을 누릅니다.
3. **RemoteForMac Host** 창이 열리면 macOS **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**에서 앱을 직접 허용합니다. 원격 입력에 필요한 권한이며 화면 기록 권한은 필요하지 않습니다.
4. YouTube 버튼을 쓰려면 Mac Safari에서 `youtube.com`을 열고 **파일 → Dock에 추가**로 웹 앱을 만든 뒤 Host의 목록에서 선택합니다. Netflix는 Safari 자동화 허용과 본인의 Netflix 로그인이 필요할 수 있습니다.

설정 창을 닫아도 Host는 메뉴 막대에서 실행될 수 있습니다. 앱을 완전히 종료하거나 Mac이 잠자기 상태라면 원격 제어가 되지 않습니다.

### 2A. iPhone 네이티브 앱으로 연결

1. Xcode에서 `RemoteTVPhone` scheme과 자신의 아이폰을 선택합니다.
2. `RemoteTVPhone` target → **Signing & Capabilities**에서 본인의 Team을 선택하고 **Run**으로 설치합니다. 번들 ID가 본인 Team에서 충돌하면 고유한 ID로 바꿉니다. 기기에서 개발자 모드와 앱 신뢰 설정이 필요할 수 있습니다. 권한 허용은 기기 소유자가 직접 합니다.
3. Mac Host에서 **아이폰 추가 등록**을 누릅니다. iPhone 앱의 **Mac 연결 QR 읽기**로 QR을 읽고 Mac에 표시된 6자리 코드를 입력합니다. 아이폰 기본 카메라 앱으로 여는 QR이 아닙니다.
4. 등록 후에는 같은 Wi-Fi에서 iPhone 앱의 등록된 Mac 목록으로 다시 연결합니다. Mac에서도 등록된 아이폰을 선택할 수 있습니다.

무료 Apple **Personal Team**으로 직접 설치한 iPhone 앱의 프로비저닝 프로필은 7일 후 만료되어 재설치가 필요할 수 있습니다. GitHub에 소스를 올리는 것만으로 다른 사람의 아이폰에 일반 앱처럼 설치되지는 않습니다. [Apple의 무료 계정 안내](https://developer.apple.com/help/account/basics/about-your-developer-account/)

### 2B. Safari 웹 리모컨으로 연결

1. Mac Host의 **Safari 웹 리모컨**에서 **웹 리모컨 켜기**를 누릅니다.
2. 아이폰 기본 카메라로 **웹 리모컨용 QR**을 읽어 Safari에서 엽니다. 공유 메뉴 → **홈 화면에 추가**를 선택합니다.
3. 홈 화면에 추가한 **RemoteForMac**을 열고 Mac에 표시된 6자리 **웹 등록 코드**를 입력합니다. 등록된 기기는 이후 자동 연결을 시도합니다.

기본 주소는 `http://remotetv.local:49373/`입니다. 이름이 동작하지 않으면 Host에 표시되는 Mac 주소를 사용하세요. 별도 웹 호스팅 비용은 없지만 **현재 웹 리모컨은 암호화되지 않은 로컬 HTTP**를 사용합니다. 본인이 신뢰하는 Wi-Fi에서만 사용하고 공유기 포트 포워딩으로 인터넷에 공개하지 마세요. [웹 리모컨 상세 안내](Docs/Web-Remote.ko.md)

## 다른 사람에게 배포하려면

- **지금 가능한 방법:** 이 저장소를 공개하고 각 사용자가 Mac/iPhone 앱을 자신의 Xcode와 Apple 계정으로 빌드합니다. iPhone 앱 설치를 피하려면 웹 리모컨을 사용합니다.
- **iPhone 앱을 일반 앱처럼 제공:** Apple Developer Program에 가입해 App Store 또는 TestFlight로 배포해야 합니다. GitHub Releases에 `.ipa`를 올리는 것만으로 누구나 설치할 수는 없습니다. [Apple의 배포 안내](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- **Mac 앱 설치 파일 제공:** 배포용 서명·공증을 갖춘 Mac 앱을 별도로 만들어 GitHub Releases 등에 올릴 수 있습니다. 현재 저장소의 개발용 빌드는 배포용 설치 파일이 아닙니다. [Apple의 Mac 배포 안내](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)

## 보안과 개인정보

네이티브 앱 연결은 QR·6자리 코드로 등록하고 TLS로 통신하며, 등록 비밀정보를 각 기기의 Keychain에 보관합니다. 웹 리모컨은 별도 등록 코드와 인증키를 사용하지만 HTTP 전송은 암호화되지 않습니다. 두 방식 모두 로컬 네트워크에서 사용하도록 설계됐습니다. 서비스 계정 로그인은 사용자가 Mac의 Safari에서 직접 합니다. 이 저장소에는 개인 페어링 비밀정보와 빌드 산출물을 포함하지 않습니다.

## 프로젝트 구조

| 경로 | 역할 |
| --- | --- |
| `MacHost/` | macOS 앱 UI, 기기 연결, 입력 이벤트, 웹 리모컨 서버 |
| `iPhoneRemote/` | iPhone 앱 UI, QR 등록, 터치패드·키보드 입력 |
| `Shared/` | 두 앱의 통신 프로토콜, 보안 연결, 제스처 판별 |
| `Resources/WebRemote/` | Safari 웹 리모컨 HTML·CSS·JavaScript |
| `Resources/` | 앱 정보, 아이콘, Mac 권한 설정 |
| `RemoteTV.xcodeproj/` | Xcode의 Mac·iPhone 앱 프로젝트와 scheme |
| `Tests/` | 공통 로직과 입력 동작 테스트 |
| `Scripts/` | 프로젝트·아이콘 생성, 검증 스크립트 |
| `Docs/` | 웹 리모컨 상세 사용 안내 |

공통 Swift 테스트는 `swift test --scratch-path build/swift-tests`로 실행할 수 있습니다. 전체 빌드 확인은 `bash Scripts/verify.sh`를 사용합니다. 일부 UI·입력 테스트는 Mac의 손쉬운 사용 권한과 실제 기기에서 별도 확인이 필요합니다.

## 라이선스

[MIT License](LICENSE). 저작권 표시와 라이선스 문구를 유지하면 복사·수정·재배포·상업적 사용이 가능합니다.
