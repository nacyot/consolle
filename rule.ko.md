# Cone 명령어 가이드

consolle는 Rails Console을 서버로 제공하는 래퍼인 `cone` 명령어를 제공합니다.

`cone` 명령어를 사용하여 Rails console 세션을 시작하고 Rails에서 코드를 실행할 수 있습니다.

Rails console과 마찬가지로 세션 내에서 실행한 결과는 유지되며, 명시적으로 종료해야만 사라집니다.

사용 전에는 `status`로 상태를 확인하고, 작업 종료 후에는 `stop`해야 합니다.

## 설치 참고사항

Gemfile이 있는 프로젝트에서는 `bundle exec`를 사용하는 것이 좋습니다:

```bash
$ bundle exec cone start
$ bundle exec cone exec 'User.count'
```

## Cone의 용도

Cone은 디버깅, 데이터 탐색, 그리고 개발 보조 도구로 사용됩니다.

개발 보조 도구로 사용할 때는 수정한 코드의 반영 여부를 항상 의식해야 합니다.

코드를 수정한 경우 서버를 재시작하거나 `reload!`를 사용해야 최신 코드가 반영됩니다.

기존 객체 역시 이전 코드를 참조하므로, 새롭게 만들어야 최신 코드를 사용합니다.

## Cone 서버 시작과 중지

`start` 명령어로 cone을 시작할 수 있습니다. 실행 환경 지정은 `RAILS_ENV` 환경변수를 사용합니다.

```bash
$ cone start # 서버 시작 (RAILS_ENV가 없으면 development)
$ RAILS_ENV=test cone start # test 환경에서 console 시작
```

시작 시 고유한 Session ID를 포함한 세션 정보가 표시됩니다:

```bash
$ cone start
✓ Rails console started
  Session ID: a1b2c3d4 (a1b2)
  Target: cone
  Environment: development
  PID: 12345
  Socket: /path/to/cone.socket
```

중지와 재시작 명령어도 제공합니다.

Cone은 타겟당 한 번에 하나의 세션만 제공하며, 실행 환경을 변경하려면 반드시 중지 후 재시작해야 합니다.

```bash
$ cone stop # 서버 중지
```

작업을 마치면 반드시 종료해 주세요.

## 세션 관리

### 세션 목록 보기

```bash
$ cone ls                    # 활성 세션만 표시
$ cone ls -a                 # 종료된 세션 포함 전체 표시
```

출력 예시:
```
ACTIVE SESSIONS:

  ID       TARGET       ENV          STATUS    UPTIME     COMMANDS
  a1b2     cone         development  running   2h 15m     42
  e5f6     api          production   running   1h 30m     15

Usage: cone exec -t TARGET CODE
       cone exec --session ID CODE
```

### 세션 히스토리

세션별 명령어 히스토리를 조회합니다:

```bash
$ cone history                    # 현재 세션 히스토리
$ cone history -t api             # 'api' 타겟의 히스토리
$ cone history --session a1b2     # 특정 세션 ID의 히스토리
$ cone history -n 10              # 최근 10개 명령어
$ cone history --today            # 오늘 실행한 명령어만
$ cone history --failed           # 실패한 명령어만
$ cone history --grep User        # 패턴으로 필터링
$ cone history --json             # JSON 형식으로 출력
```

### 세션 삭제

```bash
$ cone rm a1b2                    # 종료된 세션 ID로 삭제
$ cone rm -f a1b2                 # 강제 삭제 (실행 중이면 중지 후 삭제)
$ cone prune                      # 종료된 모든 세션 삭제
$ cone prune --yes                # 확인 없이 삭제
```

## 실행 모드

Cone은 세 가지 실행 모드를 지원합니다. `--mode` 옵션으로 지정할 수 있습니다.

| 모드 | 설명 | Ruby 요구사항 | 실행 속도 |
|------|------|--------------|----------|
| `pty` | PTY 기반, 커스텀 명령어 지원 (기본값) | 모든 버전 | ~0.6s |
| `embed-rails` | Rails 콘솔 임베딩 | Ruby 3.3+ | ~0.001s |
| `embed-irb` | 순수 IRB 임베딩 (Rails 미로드) | Ruby 3.3+ | ~0.001s |

```bash
$ cone start                      # PTY 모드 (기본값)
$ cone start --mode embed-rails   # Rails 콘솔 임베딩 (200배 빠름)
$ cone start --mode embed-irb     # 순수 IRB 임베딩 (Rails 없이)
```

### 모드 선택 기준

- **`pty`**: 원격 환경(SSH, Docker, Kamal)이나 커스텀 명령어가 필요한 경우
- **`embed-rails`**: 로컬 Rails 개발에서 빠른 실행이 필요한 경우
- **`embed-irb`**: Rails 없이 순수 Ruby 코드만 실행하는 경우

### 커스텀 명령어 (PTY 모드 전용)

PTY 모드에서는 `--command` 옵션으로 커스텀 콘솔 명령어를 지정할 수 있습니다.

```bash
$ cone start --command "docker exec -it app bin/rails console"
$ cone start --command "kamal console" --wait-timeout 60
```

### 설정 파일

프로젝트 루트에 `.consolle.yml` 파일로 기본 모드를 설정할 수 있습니다. CLI 옵션은 설정 파일보다 우선합니다.

```yaml
mode: embed-rails
# command: "bin/rails console"  # PTY 모드 전용
```

## Cone 서버 상태 확인

```bash
$ cone status
✓ Rails console is running
  Session ID: a1b2c3d4 (a1b2)
  Target: cone
  Environment: development
  PID: 12345
  Uptime: 2h 15m
  Commands: 42
  Socket: /path/to/cone.socket
```

## 코드 실행

코드를 평가하고 출력한 결과가 반환됩니다. 평가 결과는 `=> ` 접두사와 함께 출력됩니다.

```bash
$ cone exec 'User.count'
=> 1
```

변수를 사용하는 예제 (세션이 유지됩니다):

```bash
$ cone exec 'u = User.last'
=> #<User id: 1, email: "user@example.com", created_at: "2025-07-17 15:16:34.685972000 +0900", updated_at: "2025-07-17 15:16:34.685972000 +0900">

$ cone exec 'puts u'
#<User:0x00000001104bbd18>
=> nil
```

`-f` 옵션을 사용하여 Ruby 파일을 직접 실행할 수도 있습니다. Rails Runner와 달리 IRB 세션에서 실행됩니다.

```bash
$ cone exec -f example.rb
```

디버깅을 위한 `-v` 옵션(Verbose 출력)이 제공됩니다. 실행 시간 및 추가 정보를 표시합니다.

```bash
$ cone exec -v 'puts "hello, world"'
hello, world
=> nil
Execution time: 0.001s
```

## Rails 편의 명령어

자주 사용하는 Rails 작업을 위한 편의 명령어를 제공합니다:

```bash
$ cone rails env      # 현재 Rails 환경 확인
=> "development"

$ cone rails reload   # 애플리케이션 코드 리로드 (reload!)
Reloading...
=> true

$ cone rails db       # 데이터베이스 연결 정보 확인
Adapter:  postgresql
Database: myapp_development
Host:     localhost
Connected: true
```

## 코드 입력 모범 사례

### 홑따옴표 사용 (강력 권장)

`cone exec`에 코드를 전달할 때는 **항상 홑따옴표를 사용하세요**. 이는 모든 cone 사용자에게 권장되는 방법입니다:

```bash
$ cone exec 'User.where(active: true).count'
$ cone exec 'puts "Hello, world!"'
```

### --raw 옵션 사용

**Claude Code 사용자 주의: --raw 옵션을 사용하지 마세요.** 이 옵션은 Claude Code 환경에서는 필요하지 않습니다.

### 멀티라인 코드 지원

Cone은 멀티라인 코드 실행을 완벽하게 지원합니다. 멀티라인 코드를 실행하는 방법은 여러 가지가 있습니다:

#### 방법 1: 홑따옴표를 사용한 멀티라인 문자열
```bash
$ cone exec '
users = User.active
puts "Active users: #{users.count}"
users.first
'
```

#### 방법 2: 파일 사용
복잡한 멀티라인 코드는 파일에 저장하세요:
```bash
$ cone exec -f complex_task.rb
```

모든 방법은 세션 상태를 유지하므로 변수와 객체가 실행 간에 지속됩니다.

## 실행 안전장치 & 타임아웃

- 기본 타임아웃: 60초
- 타임아웃 우선순위: `CONSOLLE_TIMEOUT`(설정되고 0보다 클 때) > CLI `--timeout` > 기본값(60초)
- 사전 Ctrl‑C(프롬프트 분리):
  - 매 `exec` 전에 Ctrl‑C를 보내고 IRB 프롬프트를 최대 3초 대기해 깨끗한 상태를 보장합니다.
  - 3초 내 프롬프트가 돌아오지 않으면 콘솔 하위 프로세스를 재시작하고 요청은 `SERVER_UNHEALTHY`로 실패합니다.
  - 서버 전역 비활성화: `CONSOLLE_DISABLE_PRE_SIGINT=1 cone start`
  - 호출 단위 제어: `--pre-sigint` / `--no-pre-sigint`

### 예시

```bash
# CLI로 타임아웃 지정(환경변수 미설정 시 유효)
cone exec 'heavy_task' --timeout 120

# 최우선 타임아웃(클라이언트·서버 모두 적용)
CONSOLLE_TIMEOUT=90 cone exec 'heavy_task'

# 타임아웃 이후 복구 확인
cone exec 'sleep 999' --timeout 2      # -> EXECUTION_TIMEOUT로 실패
cone exec "puts :after_timeout; :ok"   # -> 정상 동작(프롬프트 복구)

# 호출 단위로 사전 Ctrl‑C 비활성화
cone exec --no-pre-sigint 'code'
```

### 에러 코드
- `EXECUTION_TIMEOUT`: 실행한 코드가 타임아웃을 초과함
- `SERVER_UNHEALTHY`: 사전 프롬프트 확인(3초) 실패로 콘솔 재시작, 요청 실패
