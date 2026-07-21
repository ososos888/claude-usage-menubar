# claude-usage-menubar

Claude 구독(Pro/Max/Team) 사용량을 **macOS 메뉴바**에 상시 표시하는 작은 네이티브 앱입니다. 매번 앱의 Settings → Usage 화면을 열지 않아도 세션·주간 사용률과 리셋까지 남은 시간을 한눈에 볼 수 있습니다.

```
s14% · w25% · ⏳3h58m
```

`s` = 세션(5시간 롤링), `w` = 주간, `⏳` = 세션 리셋까지 남은 시간. 클릭하면 드롭다운에 세부가 나옵니다:

```
세션: 14% 사용 · 3시간 58분 남음
주간(전체): 25% 사용 · 4일 14시간 남음
주간(Fable): 0%
─────────────
갱신: 2026-07-21T05:42:05Z
지금 새로고침
Claude 사용량 페이지 열기
종료
```

SwiftBar 같은 서드파티 앱이 필요 없습니다. 로컬 파일만 읽는 순수 메뉴바 앱이라 macOS 권한 프롬프트도 사실상 뜨지 않습니다.

## 동작 방식

```
launchd(1분)      collect.sh          usage.json         ClaudeUsageBar.app(30초 갱신)
   ────────▶  /usage 파싱·정규화  ──▶  ~/.claude-usage/  ──▶  메뉴바 + 드롭다운
```

- **데이터 소스**: Claude Code의 `claude -p "/usage" --output-format json`. 이 슬래시 명령은 로컬에서 처리되어 **토큰/사용량을 소모하지 않습니다**(`num_turns: 0`, `output_tokens: 0`).
- **왜 데몬 + 캐시 구조인가**: 앱이 매번 `claude` 를 직접 호출하면 느립니다. 백그라운드 데몬이 1분마다 수집해 JSON 캐시에 저장하고, 앱은 그 파일만 읽어 즉각 표시합니다.
- **남은 시간**은 `collect.sh` 가 리셋 시각을 절대시각(epoch)으로 저장하고, 앱이 표시 시점마다 실시간 계산하므로 분 단위로 정확히 줄어듭니다.
- 웹·데스크톱 앱·Claude Code는 **같은 사용량 풀을 공유**하므로, 한 곳(Claude Code)만 읽어도 전체 사용량입니다.

## 요구 사항

- macOS 12+
- [Claude Code](https://claude.com/claude-code) — 구독 계정으로 로그인되어 있어야 함 (API 키 인증이 아니라 구독 로그인 세션)
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq`
- Swift 컴파일러 — `xcode-select --install` (Command Line Tools)

## 설치

```bash
git clone https://github.com/ososos888/claude-usage-menubar.git
cd claude-usage-menubar
./install.sh
```

`install.sh` 가 수집 데몬 등록 + 메뉴바 앱 빌드·설치·자동실행 등록까지 처리합니다. 완료되면 메뉴바에 `s..% · w..% · ⏳..` 가 뜹니다.

## 구성

| 경로 | 역할 |
|---|---|
| `collect.sh` | `/usage` 출력을 파싱해 `~/.claude-usage/usage.json` 으로 정규화(리셋 epoch 포함). 수집 실패 시 마지막 성공값 유지 |
| `com.user.claude-usage.plist` | launchd 에이전트. 1분마다 `collect.sh` 실행, 로그인 시 자동 시작 |
| `standalone/ClaudeUsageBar.swift` | 네이티브 메뉴바 앱 소스(`NSStatusItem`). 캐시 JSON을 읽어 렌더, 남은시간 실시간 계산 |
| `standalone/build.sh` | 앱 빌드 → `~/Applications/ClaudeUsageBar.app` → launchd 자동실행 등록 |
| `swiftbar/claude_usage.1m.sh` | (선택) SwiftBar 를 선호할 때 쓰는 플러그인 대안 |

## 커스터마이징

- **수집 주기**: `com.user.claude-usage.plist` 의 `StartInterval`(초). 기본 60초.
- **화면 갱신 주기**: `ClaudeUsageBar.swift` 의 `Timer` 간격(기본 30초).
- **색 임계값**: `ClaudeUsageBar.swift` 의 `color(forPct:)` — 기본 80%↑ 빨강, 60%↑ 주황.

수정 후에는 `./standalone/build.sh` 로 재빌드하면 즉시 반영됩니다.

## 제거

```bash
launchctl unload ~/Library/LaunchAgents/com.ososos888.claudeusagebar.plist
launchctl unload ~/Library/LaunchAgents/com.user.claude-usage.plist
rm ~/Library/LaunchAgents/com.ososos888.claudeusagebar.plist
rm ~/Library/LaunchAgents/com.user.claude-usage.plist
rm -rf ~/Applications/ClaudeUsageBar.app ~/.claude-usage
```

## 주의

- `/usage` 출력 파싱은 **비공식 경로**입니다. Anthropic이 출력 형식을 바꾸면 `collect.sh` 의 파서를 수정해야 합니다(앱은 `Claude --` 로 표시됨).
- 구독 사용량을 보려면 `claude` 가 **구독 로그인 세션**으로 인증돼 있어야 합니다. `ANTHROPIC_API_KEY` 로 인증되면 API 과금 기준이라 다르게 동작할 수 있습니다.
- 사용량 한도는 Team 플랜 기준 **멤버별 개별** 적용이며, 이 위젯은 로그인한 본인 계정 기준입니다.

## License

MIT
