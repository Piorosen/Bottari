# Bottari

보따리 — 여러 서버와 클라우드를 한 창에서 다루는 macOS 파일 관리자.

FileZilla처럼 쓰지만 왼쪽은 로컬, 오른쪽은 서버로 고정하지 않고 **어느 패인에서든 어떤 위치든** 열어요.
서버 ↔ 서버, Google Drive ↔ 서버 전송, 원격 파일 편집, 이미지·영상 바로 보기, SSH 터미널과 원격 화면을 한곳에 모으는 게 목표예요.

## 요구 사항

- 실행: macOS 15 이상
- 빌드: Xcode 26 이상 (Swift 6.2+)

## 빌드

```sh
make build   # Debug 빌드
make run     # 빌드하고 실행
make test    # 핵심 패키지 테스트 (swift test)
make open    # Xcode로 열기
```

화면을 확인할 때는 창을 띄우지 않고 샘플 데이터로 PNG를 그릴 수 있어요 (Debug 빌드만):

```sh
open -n -g -j -W .build/xcode/Build/Products/Debug/Bottari.app --args -renderSnapshots /tmp/bottari-shots
```

Xcode에서 테스트를 돌리려면 `Packages/BottariKit/Package.swift`를 열고 ⌘U.

## 구조

```
Bottari/                macOS 앱 (SwiftUI)
Packages/BottariKit/    앱과 분리된 핵심 로직
  BottariCore           RemotePath, FileItem, FileProvider, LocalFileProvider
  BottariSFTP           SFTPFileProvider (Citadel), 호스트 키 기억(TOFU),
                        저장된 사이트, ~/.ssh/config, ssh-agent, 점프 호스트
```

- 모든 패인은 `FileProvider` 프로토콜로만 파일을 다뤄요. 서버 간 전송은 한쪽의 `read` 스트림을 다른 쪽 `write`에 이어 붙이는 것으로 끝나요.
- 쓰기는 대상 옆 임시 파일에 먼저 쓰고 이름을 바꿔서, 전송이 끊겨도 원래 파일이 깨지지 않아요.
- Xcode 프로젝트는 폴더 동기화 방식이라 `Bottari/` 아래에 파일을 추가해도 프로젝트 파일을 고칠 필요가 없어요.
- App Store에는 내지 않아요. 샌드박스 없이 Developer ID 서명과 공증으로 배포할 계획이에요.

## 진행 상황

- [x] 프로젝트 골격, 로컬 듀얼 패인
- [x] SFTP 연결과 탐색 (Citadel) — 키 파일 · 비밀번호, 호스트 키 확인
- [x] 저장된 사이트 · 키체인 · ssh-agent · `~/.ssh/config` 가져오기 · 점프 호스트 (엔진)
- [x] 연결 관리 화면 — 저장 · 가져오기 · 태그 · 연결 테스트, PROD 패인 띠
- [ ] 전송 큐 · 서버 간 전송
- [ ] Google Drive · S3 (rclone)
- [ ] 원격 편집, 이미지 뷰어, 영상 재생 (libmpv)
- [ ] SSH 터미널 (SwiftTerm), 원격 화면 (RoyalVNCKit), 터널
- [ ] iCloud 설정 동기화

## 라이선스

MIT
