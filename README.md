# Bottari

보따리 — 여러 서버와 클라우드를 한 창에서 다루는 macOS 파일 관리자.

FileZilla처럼 쓰지만 왼쪽은 로컬, 오른쪽은 서버로 고정하지 않고 **어느 패인에서든 어떤 위치든** 열어요.
서버 ↔ 서버, Google Drive ↔ 서버 전송, 원격 파일 편집, 이미지·영상 바로 보기, SSH 터미널과 원격 화면을 한곳에 모았어요.

## 할 수 있는 것

- **듀얼 패인** — 이 Mac, SFTP 서버, S3 (AWS · R2 · MinIO), Google Drive, iCloud Drive를 어느 쪽에서든 열기. 드래그, ⌘C/⌘V, 우클릭으로 서로 보내기.
- **전송 큐** — 서버 간 직접 전송, 동시 전송 수, 같은 이름 정책, 일시정지 · 재시도 · 이어받기, SHA-256 비교, 수정 시각 보존. 서버에서 명령을 실행할 수 있으면 `cp -a` · 압축 · 풀기는 서버에서.
- **연결 관리** — 키체인 비밀번호, ssh-agent, 키 파일, `~/.ssh/config` 가져오기, 점프 호스트, 호스트 키 확인, PROD 태그(띠 · 쓰기 전 확인 · 읽기 전용).
- **보기와 편집** — 이미지 갤러리, 영상 스트리밍 (libmpv, 받지 않고 바로 재생), 원격 편집기 (문법 색, 서버에서 바뀌면 3-way 병합), 외부 에디터로 열기.
- **원격** — SSH 터미널 (SwiftTerm, 스니펫 · 여러 서버에 동시 입력), VNC · 화면 공유 (RoyalVNCKit, SSH 터널로), SOCKS/HTTP 프록시 터널과 sshuttle.
- **사이드바와 보따리** — 즐겨찾기, 여러 서버의 파일을 모아 한 번에 보내는 보따리와 프리셋, ⌘K 명령 팔레트.
- **설정 (⌘,)**
  - 일반: 전송 기본값, 업데이트
  - 모양: 테마 프리셋 (시스템 · 종이 · 먹 · 쪽빛 밤 · 모시 · 고대비), 강조 색, 밀도, 글꼴, 서버 태그 색. 테마는 JSON 파일로 가져오고 내보내요 (`~/Library/Application Support/Bottari/themes/`).
  - 단축키: Finder식 / Commander식 (F5 복사 · F6 이동 · F7 새 폴더 · F8 삭제), 키를 눌러서 바꾸기, 겹침 표시.
  - iCloud 동기화: 연결 목록 · 즐겨찾기 · 테마 · 단축키 · 보따리 프리셋을 `iCloud Drive/Bottari/`에 JSON으로 두고 Mac끼리 합쳐요. 양쪽에서 다르게 바뀌면 "이 Mac 것 유지 / 다른 Mac 것 쓰기 / 둘 다 남기기"로 고르고, 비밀번호는 파일에 쓰지 않아요. 기본은 꺼짐.

## 요구 사항

- 실행: macOS 15 이상
- 빌드: Xcode 26 이상 (Swift 6.2+)

## 빌드

```sh
make build    # Debug 빌드
make run      # 빌드하고 실행
make test     # 핵심 패키지 테스트 (swift test)
make open     # Xcode로 열기
```

Xcode에서 테스트를 돌리려면 `Packages/BottariKit/Package.swift`를 열고 ⌘U.

화면을 확인할 때는 창을 띄우지 않고 샘플 데이터로 PNG를 그릴 수 있어요 (Debug 빌드만). 편집기 · 플레이어 · VNC · 설정 · 동기화는 스스로 점검해서 `*-check.txt`에 PASS/FAIL을 남겨요. 사용자의 테마 · 단축키 · 연결 목록은 건드리지 않아요.

```sh
open -n -g -j -W .build/xcode/Build/Products/Debug/Bottari.app --args -renderSnapshots /tmp/bottari-shots
```

## 배포

App Store에는 내지 않아요. 샌드박스 없이 Developer ID로 서명하고 공증해서 DMG로 나눠 주고, 업데이트는 Sparkle로 받아요.

처음 한 번:

1. Developer ID Application 인증서를 키체인에 둡니다.
2. 공증용 프로필을 만듭니다: `xcrun notarytool store-credentials bottari-notary --apple-id … --team-id …`
3. Sparkle 키를 만듭니다: `scripts/sparkle-keys.sh` (개인 키는 로그인 키체인에, 출력된 공개 키를 아래에).
4. `cp Config/release.env.example Config/release.env` 하고 `TEAM_ID`, `SPARKLE_PUBLIC_KEY`를 채웁니다 (이 파일은 커밋하지 않아요).

릴리스마다:

```sh
make release   # .build/release/ 에 Bottari-<버전>.dmg, .zip, appcast.xml
gh release create v0.1.0 .build/release/Bottari-0.1.0.dmg .build/release/Bottari-0.1.0.zip .build/release/appcast.xml
```

앱은 `https://github.com/Piorosen/Bottari/releases/latest/download/appcast.xml`에서 업데이트를 찾아요. 공개 키가 없는 빌드(Debug, `make package`)는 업데이트를 확인하지 않아요. `make package`는 서명 없이 같은 단계를 거쳐 파이프라인만 확인해요.

## 구조

```
Bottari/                macOS 앱 (SwiftUI)
  Panes/ Sidebar/       패인, 사이드바, 보따리
  Transfers/            전송 막대와 목록, 연결 유지
  Sites/                연결 관리
  Viewers/              갤러리, 플레이어, 편집기
  Remote/ Tunnels/      터미널, 원격 화면, 터널
  Settings/             테마, 단축키, iCloud 동기화, 설정 창
  Debug/                스냅샷 렌더러와 샘플 데이터
Packages/BottariKit/    앱과 분리된 핵심 로직
  BottariCore           RemotePath, FileItem, FileProvider, LocalFileProvider, 3-way 동기화 폴더
  BottariSFTP           SFTP (Citadel), 저장된 사이트, ~/.ssh/config, 점프 호스트, PTY, 포트 포워딩, 프록시
  BottariTransfer       전송 큐, 파일 캐시
  BottariEditor         문법 색, 문자 인코딩, 3-way 병합
  BottariPlayer         libmpv (MPVKit) 스트리밍
  BottariRemote         SwiftTerm, RoyalVNCKit
  BottariCloud          S3 (SigV4), Google Drive (AppAuth)
Config/                 Info.plist 추가 키, 릴리스 설정 예시
scripts/                release.sh, sparkle-keys.sh
```

- 모든 패인은 `FileProvider` 프로토콜로만 파일을 다뤄요. 서버 간 전송은 한쪽의 `read` 스트림을 다른 쪽 `write`에 이어 붙이는 것으로 끝나요. 읽기는 받는 쪽이 가져가는 만큼만 해서 큰 파일도 메모리에 쌓이지 않아요.
- 쓰기는 대상 옆 임시 파일에 먼저 쓰고 이름을 바꿔서, 전송이 끊겨도 원래 파일이 깨지지 않아요.
- Xcode 프로젝트는 폴더 동기화 방식이라 `Bottari/` 아래에 파일을 추가해도 프로젝트 파일을 고칠 필요가 없어요.

## 라이선스

MIT. libmpv(MPVKit)는 LGPL 빌드를 써요.
