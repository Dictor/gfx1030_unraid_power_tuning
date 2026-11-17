# Project Agent Rules (AGENTS.md)

## 1. Git Auto-Commit & Push Rule (필수)
- 프로젝트 내 코드, 스크립트(`scripts/*.sh`, `build_wsl.sh`), 패치(`patches/*.patch`), 문서(`*.md`) 등 **파일에 변경 사항이 발생할 때마다 작업을 마무리하기 전에 반드시 `git add`, `git commit`, `git push`까지 자동으로 수행**해야 합니다.
- 사용자가 별도로 "푸시해줘"라고 요청하지 않아도 파일 수정이 완료되면 즉시 원격 저장소(`origin/master`)에 반영합니다.

## 2. Shell Script & Patch Formatting Rule
- Unraid 및 WSL에서 실행되는 모든 셸 스크립트(`*.sh`)와 커널 패치 파일(`*.patch`)은 반드시 **Unix LF(`\n`) 줄바꿈**을 유지해야 합니다 (`CRLF` 금지).
- Unraid 터미널 명령어를 사용자에게 안내할 때는 줄바꿈 시 깨질 수 있는 복잡한 한 줄 문법이나 중괄호 확장(`{a,b}`) 대신 직관적이고 단순한 개별 명령어를 사용합니다.
