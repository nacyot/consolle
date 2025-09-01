# Cone 명령어 가이드

consolle는 Rails Console을 서버로 제공하는 래퍼인 `cone` 명령어를 제공합니다.

`cone` 명령어를 사용하여 Rails console 세션을 시작하고 Rails에서 코드를 실행할 수 있습니다.

Rails console과 마찬가지로 세션 내에서 실행한 결과는 유지되며, 명시적으로 종료해야만 사라집니다.

사용 전에는 `status`로 상태를 확인하고, 작업 종료 후에는 `stop`해야 합니다.

## Cone의 용도

Cone은 디버깅, 데이터 탐색, 그리고 개발 보조 도구로 사용됩니다.

개발 보조 도구로 사용할 때는 수정한 코드의 반영 여부를 항상 의식해야 합니다.

코드를 수정한 경우 서버를 재시작하거나 `reload!`를 사용해야 최신 코드가 반영됩니다.

기존 객체 역시 이전 코드를 참조하므로, 새롭게 만들어야 최신 코드를 사용합니다.

## Cone 서버 시작과 중지

`start` 명령어로 cone을 시작할 수 있으며, `-e`로 실행 환경을 지정할 수 있습니다.

```bash
$ cone start # 서버 시작
$ RAILS_ENV=test cone start # test 환경에서 console 시작
```

중지와 재시작 명령어도 제공합니다.

Cone은 한 번에 하나의 세션만 제공하며, 실행 환경을 변경하려면 반드시 중지 후 재시작해야 합니다.

```bash
$ cone stop # 서버 중지
```

작업을 마치면 반드시 종료해 주세요.

## Cone 서버 상태 확인

```bash
$ cone status
✓ Rails console is running
  PID: 36384
  Environment: test
  Session: /Users/ben/syncthing/workspace/karrot-inhouse/ehr/tmp/cone/cone.socket
  Ready for input: Yes
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

디버깅을 위한 `-v` 옵션(Verbose 출력)이 제공됩니다.

```bash
$ cone exec -v 'puts "hello, world"'
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
