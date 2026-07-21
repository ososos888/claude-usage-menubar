# claude-usage-menubar

Claude 구독(Pro/Max/Team) 사용량을 **macOS 메뉴바**에 상시 표시하는 [SwiftBar](https://github.com/swiftbar/SwiftBar) 위젯입니다. 매번 앱의 Settings → Usage 화면을 열지 않아도 세션·주간 사용률과 리셋까지 남은 시간을 한눈에 볼 수 있습니다.

```
d11% · w24% · ⏳4h16m
```

`d` = 세션(5시간 롤링), `w` = 주간, `⏳` = 세션 리셋까지 남은 시간. 클릭하면 드롭다운에 세부가 나옵니다:

```
세션: 11% 사용 · 4시간 17분 남음 (리셋 Jul 21 at 6:40pm (Asia/Seoul))
주간(전체): 24% 사용 · 4일 14시간 남음 (리셋 Jul 26 at 4am (Asia/Seoul))
주간(Fable): 0%
```

## 동작 방식

```
launchd (1분마다)        SwiftBar (1분마다)
   collect.sh  ──▶  ~/.claude-usage/usage.json  ──▶  claude_usage.1m.sh  ──▶  메뉴바
```

- **데이터 소스**: Claude Code의 `claude -p "/usage" --output-format json`. 이 슬래시 명령은 로컬에서 처리되어 **토큰/사용량을 소모하지 않습니다**(`num_turns: 0`, `output_tokens: 0`).
- **왜 데몬 + 캐시 구조인가**: 위젯이 매번 `claude` 를 직접 호출하면 느립니다. 백그라운드 데몬이 주기적으로 수집해 JSON 캐시에 저장하고, 위젯은 그 파일만 읽어 즉각 표시합니다.
- **남은 시간**은 위젯이 표시 시점마다 실시간 계산하므로 1분 단위로 정확히 줄어듭니다.
- 웹·데스크톱 앱·Claude Code는 **같은 사용량 풀을 공유**하므로, 한 곳(Claude Code)만 읽어도 전체 사용량입니다.

## 요구 사항

- macOS
- [Claude Code](https://claude.com/claude-code) — 구독 계정으로 로그인되어 있어야 함 (API 키 인증이 아니라 구독 로그인 세션)
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq`
- [SwiftBar](https://github.com/swiftbar/SwiftBar) — `brew install --cask swiftbar`

## 설치

```bash
git clone https://github.com/ososos888/claude-usage-menubar.git
cd claude-usage-menubar
./install.sh
```

그다음 SwiftBar를 실행해 Plugin Folder를 `~/SwiftBarPlugins` 로 지정하면 끝입니다. (자세한 안내는 `install.sh` 출력 참고)

## 구성 파일

| 파일 | 역할 |
|---|---|
| `collect.sh` | `/usage` 출력을 파싱해 `~/.claude-usage/usage.json` 으로 정규화. 수집 실패 시 마지막 성공값 유지 |
| `claude_usage.1m.sh` | SwiftBar 플러그인. 캐시 JSON을 읽어 메뉴바/드롭다운 렌더, 남은시간 실시간 계산 |
| `com.user.claude-usage.plist` | launchd 에이전트. 1분마다 `collect.sh` 실행, 로그인 시 자동 시작 |

## 커스터마이징

- **수집 주기**: `com.user.claude-usage.plist` 의 `StartInterval`(초). 기본 60초. `/usage`가 무료라 짧게 잡아도 되지만 매번 `claude` 프로세스 기동 비용(~0.6초)은 있음.
- **위젯 갱신 주기**: 플러그인 파일명의 `.1m.` 부분(SwiftBar 규칙). `.30s.` 로 바꾸면 30초.
- **색 임계값**: `claude_usage.1m.sh` 의 `color_for()` — 기본 80%↑ 빨강, 60%↑ 주황.

## 제거

```bash
launchctl unload ~/Library/LaunchAgents/com.user.claude-usage.plist
rm ~/Library/LaunchAgents/com.user.claude-usage.plist
rm -rf ~/.claude-usage
rm ~/SwiftBarPlugins/claude_usage.1m.sh
```

## 주의

- `/usage` 출력 파싱은 **비공식 경로**입니다. Anthropic이 출력 형식을 바꾸면 `collect.sh` 의 파서를 수정해야 합니다(위젯은 `-- %` 로 표시됨).
- 구독 사용량을 보려면 `claude` 가 **구독 로그인 세션**으로 인증돼 있어야 합니다. `ANTHROPIC_API_KEY` 로 인증되면 API 과금 기준이라 다르게 동작할 수 있습니다.
- 사용량 한도는 Team 플랜 기준 **멤버별 개별** 적용이며, 이 위젯은 로그인한 본인 계정 기준입니다.

## License

MIT
