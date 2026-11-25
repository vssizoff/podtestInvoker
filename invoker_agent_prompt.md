# Промпт для coding agent: реализация podtest Invoker на Zig

Ты — senior systems engineer. Нужно разработать с нуля исполнитель **podtest Invoker** для системы автоматической проверки решений по программированию.

Результат должен быть рабочей программой, а не только каркасом или демонстрационным мокапом. Реализацию делай поэтапно, с компилируемыми промежуточными состояниями, тестами и документацией. Не скрывай технические ограничения Zig/Podman/gRPC и не подменяй реальные операции заглушками.

Код разместить в ~/programming/podtestInvoker

---

# 1. Сначала изучи входные контракты и контекст

В доступном проекте/контексте предоставлены:

1. `control.proto` — текущая заготовка gRPC API podtest Invoker ↔ Backend.
2. `openapi.yaml` описывает публичный Backend API и дан только для контекста. Invoker не должен обращаться к нему. Источник контракта Invoker ↔ Backend — `control.proto`, NATS-схемы и согласованный контракт artifact URLs. Если `openapi.yaml` недоступен, продолжай работу без него.
3. Архитектура podtest — два execution formats, `standard` и `scripted_lua`, общий Execution Engine, отдельный Lua Runner process, PostgreSQL/NATS/S3/Backend.

Перед кодированием:

- внимательно прочитай `control.proto` и проверь все field numbers, `go_package`, enums, current service methods;
- не используй `openapi.yaml` как замену внутреннему gRPC контракту;
- зафиксируй какие gRPC methods уже существуют, какие необходимы для lease/cancel/artifact upload и отсутствуют;
- проверь фактическую версию `zig version` и Podman на build/test host;
- составь краткий implementation plan и ADR по gRPC/Protobuf/NATS Zig dependencies до написания большого объёма кода.

## 1.1. Старый код Invoker

У пользователя есть старый проект `~/programming/podtestInvokerOld`.

**Не изменяй его ни при каких обстоятельствах.** Не форматируй, не переименовывай, не обновляй зависимости, не удаляй и не используй его как рабочую директорию.

Новый Invoker создаётся в отдельном каталоге/проекте. Если старый каталог доступен в твоём окружении, можешь изучить его исключительно read-only и только как справочный материал. Не копируй решения из него автоматически: текущая спецификация и `control.proto` важнее. Если старого каталога в окружении нет, не блокируй работу и не пытайся создавать его.

---

# 2. Контекст podtest

Podtest — собственная тестирующая система для олимпиадных задач и учебных контестов.

Backend написан на Go, Frontend — Vue + TypeScript. Центральная инфраструктура: PostgreSQL, NATS JetStream, S3-compatible storage (локально MinIO), OpenFGA и Nginx. Центральный Backend/Frontend stack собирается через Podman Compose. Invoker-ы являются отдельными execution nodes, могут работать на разных Linux-хостах и подключаются к общей инфраструктуре через защищённую сеть.

Backend — источник истины о:

- пользователях, курсах, контестах и индивидуальных участниках;
- задачах и immutable revisions;
- submissions и judging attempts;
- тестовых результатах, verdicts и базовых баллах посылок;
- Grader snapshots и опубликованных participant scores;
- очереди, отменах и состоянии Invoker Fleet.

Invoker не имеет прямого доступа к PostgreSQL и OpenFGA. Он получает job через NATS JetStream, подтверждает claim через gRPC, скачивает артефакты по временным URL, запускает исполнение, отправляет события и артефакты Backend.

## 2.1. Форматы исполнения

Есть ровно два встроенных формата:

- `standard` — Standard Executor для Polygon-задач;
- `scripted_lua` — пользовательский `runner.lua` из архива ревизии задачи.

HTTP, SQL, run-twice, interactive и другие специальные схемы не являются отдельными встроенными formats. Они реализуются Lua-сценариями и готовыми Lua-библиотеками поверх общего Execution Engine.

Standard Executor и Lua API используют один Execution Engine: Podman images, containers, networks, volumes, stdio, pipes, resource limits, metrics и artifacts.

## 2.2. Ревизии и идентификаторы

- `submission_id` — неизменяемая посылка.
- `judging_attempt_id` — логическая попытка проверить посылку по определённой ревизии задачи.
- `task_revision_id` — immutable revision целиком.
- `run_id` — фактический запуск на конкретном Invoker/generation; уникален для одной выдачи execution lease.
- `invoker_id` — стабильный ID экземпляра Invoker.
- `process_epoch` — UUID процесса Invoker, меняющийся при каждом старте.
- `fencing_token`/lease token — защищает от старого процесса, который продолжил работу после истечения lease.

Ревизия включает statement/resources, тесты, checker, interactor, language configs, Containerfiles, runner.lua, Lua libraries/config, scoring config, grader config и другие компоненты. После публикации она неизменяема.

Повторная пользовательская/менеджерская проверка создаёт новый JudgingAttempt. Аварийное восстановление того же attempt может создать новый `run_id`/generation; события со старым fencing token не должны приниматься Backend.

## 2.3. Оценивание

- Standard Executor или Lua выставляет **базовый балл конкретной посылки** (`problem_score`) и, если применимо, verdicts/test scores/subgroup scores.
- Lua может отправить произвольную строку verdict, test score, subgroup score, problem score и `checker_metadata`.
- Backend валидирует структуру, IDs, состояние attempt, конечность/диапазон чисел и идемпотентность событий.
- Invoker не рассчитывает итоговую оценку участника по истории посылок.
- Grader — отдельная подсистема Backend/Grader Worker, которая может учитывать несколько посылок одного или разных участников; Invoker не запускает Grader и не имеет к нему доступа.
- `problem_score` не следует выводить молча из test scores. Успешный run должен отправить базовый score в соответствии с revision scoring contract.

---

# 3. Обязательный технологический стек

- Zig. В окружении пользователя ранее был `zig version 0.17.0` (pacman package `0.17.0-1.1`). Не обновляй компилятор автоматически. Зафиксируй фактически проверенную версию и зависимости в `build.zig.zon`.
- Linux x86-64 only.
- Lua 5.5.
- Rootless Podman через HTTP REST API по Unix socket.
- NATS JetStream.
- gRPC + Protobuf для Backend Control API.
- S3-compatible artifacts download/upload по временным URLs.
- cgroup v2 с делегированными `cpu`/`memory` контроллерами.
- systemd service для production host deployment.

Не использовать Podman CLI как основной runtime API. Не передавать Podman socket Lua Runner.

## 3.1. Важное техническое исследование

До реализации сделай небольшие проверочные prototypes:

1. Zig gRPC client ↔ Go gRPC test server с текущим `control.proto`.
2. Zig Protobuf encode/decode для всех используемых сообщений.
3. Zig NATS JetStream durable pull consumer: fetch, ack, nak, redelivery.
4. Zig HTTP client по Unix socket к локальному Podman Libpod API.
5. Zig filesystem/child-process/cgroup operations на выбранном toolchain.

Не выбирай библиотеку только по README. Проверь её `build.zig.zon`, совместимость с фактическим Zig, integration tests, ownership rules, cancellation и error mapping.

На текущий момент NATS имеет проект `nats-io/nats.zig` (Zig client; JetStream pull consumers поддерживаются, проект pre-1.0, API может изменяться; mTLS в заявленных ограничениях пока не реализован). Это кандидат, но перед pinning нужно проверить текущую версию и необходимые auth/TLS features. Альтернативы — NATS C client через FFI или другой поддерживаемый путь.

Для gRPC в Zig нет official grpc.io implementation. Рассмотри в первую очередь официальный gRPC C core через Zig C interop. Чисто-Zig реализацию допускай только после успешного interoperability suite с Go gRPC. Если стабильной реализации на выбранной версии Zig не существует, предложи минимальный trusted transport helper как отдельный ADR, но не меняй язык всего Invoker без одобрения.

---

# 4. Архитектура программы

Сделай один основной Zig executable `podtest-invoker` с модульной архитектурой. Внутри него работают:

- `InvokerCore` — конфигурация, lifecycle, graceful shutdown;
- `NatsConsumer` — pull jobs;
- `BackendControlClient` — heartbeat, claim, lease renew, event report, command stream, artifact grants;
- `RunSupervisor` — state machine одного run;
- `WorkspaceManager` — рабочие каталоги и безопасная распаковка;
- `ArtifactDownloader` / `ArtifactSpooler` — S3 downloads/uploads;
- `StandardExecutor` — Polygon execution;
- `LuaRunnerManager` — запускает отдельный Lua process на каждый scripted run;
- `LuaRpcServer` — run-scoped Unix Domain Socket RPC для Lua Runner;
- `ExecutionEngine` — общий execution API;
- `PodmanClient` — REST client поверх Unix socket;
- `ImageManager`, `ContainerManager`, `NetworkManager`, `VolumeManager`;
- `IOManager`, `PipeManager`;
- `ResourceManager`, `MetricsManager`;
- `OwnershipRegistry`;
- `EventOutbox` — локальный durable spool событий;
- `CleanupManager`, `Janitor`;
- `HealthReporter`, `Observability`.

Lua Runner является отдельным дочерним процессом, не библиотекой внутри Invoker.

Предлагаемая структура исходников:

```text
src/
  main.zig
  app/
  control/
  podman/
  execution/
  executor/standard/
  executor/scripted_lua/
  lua/
  workspace/
  artifacts/
  cleanup/
  calibration/
  observability/
  tests/
proto/control.proto
examples/
docs/
```

Можешь адаптировать структуру при сохранении границ ответственности.

---

# 5. NATS job delivery

## 5.1. Модель

Backend публикует job advertisement в NATS JetStream. Архивы не находятся в job message.

Минимальное сообщение:

```json
{
  "schema_version": 1,
  "job_id": "uuid",
  "run_id": "uuid",
  "judging_attempt_id": "uuid",
  "submission_id": "uuid",
  "task_id": "uuid",
  "task_revision_id": "uuid",
  "contest_id": "uuid",
  "contest_problem_id": "uuid",
  "execution_format": "scripted_lua",
  "execution_format_version": 1,
  "created_at": "2026-11-24T12:00:00Z"
}
```

NATS stream/subject/consumer name должны приходить из config.

## 5.2. Pull/ack flow

1. Invoker имеет свободный slot.
2. Выполняет pull (количество запрошенных сообщений не превышает свободную capacity).
3. Получает job metadata.
4. Вызывает gRPC `Claim(invoker_id, attempt_id, run_id)`.
5. При временной ошибке Backend — не ACK; NAK с backoff или retry.
6. При stale/already claimed/terminal/cancelled job — ACK и игнорировать.
7. При успешном claim — сохранить lease/fencing, ACK NATS job и запустить run.
8. После claim ownership контролируется Backend lease; при падении Invoker Backend по истечении lease решает вопрос повторной выдачи.

Использовать JetStream explicit ack и durable pull consumer. Повторная доставка нормальна; idempotency обеспечивается Claim и run fencing, а не предположением «сообщение пришло один раз».

Не забирай задачи, если free slots = 0, Podman недоступен или workspace/spool достиг критического заполнения.

---

# 6. Backend gRPC Control API

## 6.1. Текущий `control.proto`

Входной контракт содержит:

```proto
syntax = "proto3";
package podtest.invoker.v1;
option go_package = "podtest/internal/invokerpb";

service Control {
  rpc Heartbeat(HeartbeatRequest) returns (Acknowledgement);
  rpc Claim(ClaimRequest) returns (ClaimResponse);
  rpc Report(Event) returns (Acknowledgement);
}
```

В нём уже есть HeartbeatRequest (invoker_id, protocol_version, execution_formats, capacity, load), ClaimRequest (invoker_id, attempt_id, run_id), ClaimResponse (lease_expires_unix, source_url, bundle_url) и Event (event_id, attempt_id, run_id, submission_id, invoker_id, sequence, schema_version, occurred_at, kind, verdict, optional score string, test_id, subgroup_id, artifact_id).

Event kinds: RUN_STARTED, BUILD_STARTED, BUILD_LOG_CHUNK, BUILD_FINISHED, TEST_STARTED, TEST_FINISHED, SUBGROUP_SCORE, PROBLEM_SCORE, ARTIFACT_CREATED, RUNNER_ERROR, RUN_TIMEOUT, RUN_CANCELLED, RUN_FINISHED.

**Не меняй существующие protobuf field numbers, package и имена методов без необходимости.** Для новых полей используй новые номера; удалённые поля reserve.

## 6.2. Недостающие методы

Текущая заготовка не содержит явной доставки Cancel commands, lease renewal и artifact upload grants. До production integration согласуй и добавь backward-compatible расширения, например:

```proto
rpc RenewLease(RenewLeaseRequest) returns (RenewLeaseResponse);
rpc WatchCommands(WatchCommandsRequest) returns (stream Command);
rpc CreateArtifactUpload(CreateArtifactUploadRequest)
    returns (ArtifactUploadTarget);
```

`Command` должен включать как минимум `CancelRun` с attempt_id, run_id, fencing token, reason и deadline.

`ClaimResponse` нужно дополнить lease/fencing token, artifact digests/sizes и при необходимости limits profile. Уточни семантику `source_url` (solution artifact) и `bundle_url` (task revision bundle); не менять их местами.

Для больших artifacts запрашивать ограниченный upload target / presigned URL у Backend, загружать файл в S3 напрямую, затем отправлять `ARTIFACT_CREATED` с artifact metadata. Не передавать сотни MiB в gRPC `Event`.

Если Backend пока не реализовал расширенные методы, создай interface + fake/test server и чётко обозначь integration blocker. Не симулируй успешный cancel/lease/artifact upload в production code.

## 6.3. gRPC constraints

- Service credentials, не OIDC browser session.
- TLS/mTLS либо согласованная service auth; secrets не коммитить.
- Deadlines на RPC.
- Reconnect с bounded exponential backoff + jitter.
- Типизированная обработка gRPC status codes.
- `event_id` стабилен между retry; duplicate ACK нормально.
- `sequence` строго возрастает в пределах `run_id` и восстанавливается из event spool.
- `score` передаётся canonical decimal string (не сериализовать IEEE-754 произвольным способом); `NaN`/Infinity запрещены.
- ACK означает, что Backend атомарно принял или распознал duplicate event.

Event `BUILD_LOG_CHUNK` не должен отправляться без содержимого/ссылки: build log потоково загружается в Artifact Storage, событие содержит ссылку на Artifact. Для live progress можно использовать отдельное metadata event.

---

# 7. Run state machine и lifecycle

Каждый run должен иметь явную state machine. Пример:

```text
received
  -> claimed
  -> downloading
  -> preparing_workspace
  -> starting_executor
  -> running
  -> finalizing_artifacts
  -> reporting_terminal
  -> cleanup
  -> finished

Любое активное состояние может перейти в:
  cancelling -> cleanup -> cancelled
  timed_out -> cleanup -> timed_out
  failed -> cleanup -> failed
```

Не допускай двух одновременных supervisors с одним `run_id` в одном процессе.

## 7.1. Run lifecycle

1. Получить job из NATS.
2. Claim через Backend.
3. Сохранить lease/fencing token локально.
4. Скачать `bundle_url` и `source_url` в temp files.
5. Проверить размеры и SHA-256.
6. Безопасно распаковать task bundle и solution в уникальный workspace.
7. Проверить manifest/format/api version.
8. Запустить `StandardExecutor` или `ScriptedLuaExecutor`.
9. События и artifacts писать в outbox/spool и доставлять Backend.
10. Дождаться terminal executor result.
11. Завершить artifacts upload и отправить terminal event.
12. Cleanup всех resources и workspace после сохранения требуемых artifacts.

`task_revision_id` и `task_bundle_digest` должны оставаться доступны в run metadata и event context.

---

# 8. Task bundle и workspace security

Invoker получает уже подготовленный immutable execution bundle от Backend. Polygon ZIP импортируется/валидируется в Backend; Invoker не должен выполнять полный Polygon import.

Workspace — отдельный каталог на run. Файлы из task bundle размещаются в task root, solution artifact — в `solution/`.

Архив extraction обязан защищаться от:

- absolute paths;
- `..` traversal;
- symlink/hardlink escape;
- device/FIFO/socket entries;
- path collisions;
- zip/tar bombs;
- чрезмерного числа файлов, размера и глубины.

Не полагайся на простое удаление `../` из строки. Используй dirfd-based resolution, `openat2` с подходящими resolve flags или эквивалентную race-safe реализацию. Workspace root и spool должны иметь quotas.

Внутренний canonical archive format (`tar.zst`, `tar.gz` или другой) пока не утверждён. Сначала согласуй с Backend; не угадывай формат по расширению. Bundle должен содержать versioned `manifest.json`.

---

# 9. Podman Adapter и Execution Engine

## 9.1. Подключение

- Rootless Podman REST API через configured Unix socket.
- Не использовать Podman CLI для create/build/start/stop/inspect/cleanup.
- Предпочтительно Libpod API; закрепить и проверить API compatibility matrix.
- HTTP client поддерживает streaming responses и отмену запросов.
- У каждого Podman operation есть deadline и mapping error -> internal typed error.

Podman API предоставляет Docker-compatible и Libpod layers; rootless socket обычно находится под `$XDG_RUNTIME_DIR/podman/podman.sock`, systemd socket activation поддерживается. Официальные docs: https://docs.podman.io/en/latest/markdown/podman-system-service.1.html

## 9.2. Общие managers

Реализовать:

- ImageManager: build, inspect, digest, ownership, cleanup/cache refs.
- ContainerManager: create/start/start_group/stop/kill/wait/inspect/remove.
- NetworkManager: create internal network, attach/detach, cleanup.
- VolumeManager: mounts только из run workspace/managed tmpfs.
- IOManager: stdin/stdout/stderr modes.
- PipeManager: streams between containers, backpressure, EOF.
- ResourceManager: apply limits.
- MetricsManager: raw/normalized CPU, memory peak, OOM, exit status.
- OwnershipRegistry: per-run opaque handles.
- ArtifactManager: spool and upload.

All handles opaque, tagged by `invoker_id`, `process_epoch`, `run_id`, resource kind and internal Podman ID. Lua cannot provide raw Podman IDs.

## 9.3. ContainerSpec allowlist

Не проксировать произвольный Podman JSON. Использовать типизированную структуру с allowlist:

- image handle;
- command/args, env;
- working dir;
- run-owned networks;
- safe workspace mounts;
- CPU/RAM/PIDs/disk/time/output limits;
- user;
- readonly rootfs where possible;
- minimal capabilities;
- seccomp;
- no-new-privileges;
- no devices/host namespaces/host network.

Запрещены privileged containers, host mounts arbitrary paths, host PID/IPC/network, Podman socket, dangerous capabilities and host devices.

## 9.4. Resource enforcement

Resource limits применяются самим Invoker и cgroups, а не остаются на усмотрение Lua:

- CPU quota;
- RAM limit;
- swap off by default;
- PIDs limit;
- wall-time watchdog;
- disk/workspace quota;
- output cap;
- run-level aggregate limits (containers/images/networks/memory/disk/build time).

Backend/Task manifest может просить лимиты ниже hard caps Invoker. Никогда не разрешай задаче/автору превышать host hard caps.

Default global run timeout из текущего плана — 300 секунд. Default normal container stop grace — 500 ms. Backend cancellation убивает Lua Runner и все resources без grace period. Ресурсные пределы должны быть configurable и иметь безопасные ненулевые defaults.

## 9.5. Build networking

Сборка получает network egress policy, потому что автор задаёт build dependencies. Runtime network отдельно и не имеет произвольного Internet.

- Не использовать host network для build.
- Build egress не видит Podman socket, Backend internals, local host services и другие run networks.
- Build time/CPU/RAM/disk ограничены.
- Build cancellation удаляет Buildah/Podman leftovers.
- Build logs streams to disk-backed artifact spool.

## 9.6. Runtime networking

Контейнер без сети должен получать явный `network=none`. Не полагайся на Podman rootless defaults (в некоторых configurations используется pasta). Для task services — отдельная internal network данного run. Runtime Internet запрещён. Не предоставлять host network или произвольные routes.

---

# 10. Stdio и Pipe API

Режимы отдельно для каждого stdin/stdout/stderr, default `none`:

| Mode     | stdin                                | stdout/stderr                                              |
| -------- | ------------------------------------ | ---------------------------------------------------------- |
| none     | immediate EOF                        | not collected unless explicit diagnostic capture           |
| once     | send provided binary bytes, then EOF | capture history for post-exit retrieval                    |
| realtime | write/close during execution         | read chunks with timeout/EOF distinction; preserve history |
| pipe     | receive another container stdout     | connect to another container stdin                         |

Все данные бинарно-безопасны. Timeout, EOF и IO error — разные ответы.

`start_group` подготавливает несколько containers/pipe endpoints, затем запускает их best-effort близко по времени. Не утверждай, что Podman API обеспечивает атомарный одновременный start.

Pipe:

- можно создавать циклы;
- ограниченные buffers;
- backpressure обязателен;
- EOF/half-close/broken pipe имеют ясную семантику;
- peer termination policy задаётся явно, нет автоматической транзитивной остановки всей группы по умолчанию;
- данные не буферизуются без лимита в RAM.

История stdio была согласована с лимитом 512 MiB суммарно на контейнер по трём потокам. Сохрани это как configurable default/limit, но хранение делай disk-backed, а не большим RAM buffer. Превышение hard cap останавливает контейнер с `output_limit`, накопленный prefix остаётся доступен.

---

# 11. CPU/RAM metrics and calibration

## 11.1. CPU time

- Raw CPU time считывать из cgroup v2 `cpu.stat: usage_usec` (user+system, сумма по ядрам).
- Сохранять финальное значение до удаления cgroup/container.
- `cpu_time_raw()` возвращает raw time.
- `cpu_time()` возвращает normalized estimate на основе benchmark factor.

## 11.2. Calibration

Reference benchmark встроен в поставку Invoker, единый по версии и convention для всего fleet. При старте/в предусмотренные безопасные периоды benchmark выполняется N раз на одном ядре, берётся медиана, рассчитывается factor. Передавать Backend:

- benchmark ID/version;
- raw reference time;
- calibration factor;
- calibrated timestamp;
- Invoker hardware metadata.

Нормализация приближённая, не обещать универсальную погрешность 10%. Raw CPU time всегда сохраняется. Не менять factor посреди активного contest без согласованной процедуры.

## 11.3. RAM/OOM

- cgroup `memory.max`;
- `memory.swap.max=0` where supported;
- OOM detection через `memory.events`/Podman inspect;
- `wait()` возвращает `oom_killed=true`, reason `oom`.

Wall timeout enforcement независим от Lua polling.

---

# 12. Lua Runner process и local RPC

## 12.1. Отдельный процесс

Каждый `scripted_lua` run получает отдельный Lua 5.5 process. Он не имеет Podman socket, Backend/NATS/S3 secrets, БД и произвольного network access.

Invoker создаёт run-specific UDS и передаёт его runner process. Использовать peer credentials и run-scoped random token; RPC messages содержат `run_id`/request_id/deadline.

## 12.2. Sandbox

Отдельный process — только boundary отказа, а не полная sandbox. Обязательно:

- unprivileged UID/GID;
- restricted mount namespace/rootfs;
- доступ только к текущей workspace и required readonly runtime libraries;
- no network;
- seccomp/Landlock/namespaces или equivalent hardening;
- cgroups CPU/RAM/PIDs;
- ограничение FDs, output и syscalls;
- запрет запуска arbitrary host processes;
- process group/cgroup kill на cancel;
- нет Podman socket/Backend credentials.

Lua libraries: оставить base/string/table/math/utf8/coroutine. Отключить опасный `os`, `io`, `debug`, `dofile`, `loadfile`, arbitrary C modules. `require` разрешить только для allowlisted built-in/task modules. `print` идёт в ограниченный run log.

## 12.3. Instruction and memory limits

Использовать Lua instruction hook `lua_sethook(..., LUA_MASKCOUNT, ...)`; allocator/process cgroup ограничивает память. Отдельный watchdog прекращает процесс по wall-time. Lua coroutines кооперативные: бесконечный цикл без yield не уступает управление, поэтому instruction hook обязателен.

C API functions, которые yield, должны корректно использовать `lua_yieldk`/continuations, учитывать non-yieldable C-call boundaries. Протестировать две concurrent coroutines, каждая ожидает I/O другого container.

## 12.4. Lua coroutine model

`spawn(fn)` начинает coroutine; `handle:join()` ждёт её. `stdout_read`, `wait`, `sleep`, и другие blocking-looking functions yield-ят current coroutine, а scheduler возобновляет её по I/O completion. Не делать блокирующий синхронный вызов, который останавливает scheduler всего run.

---

# 13. Lua API v1 — требуемые способности

Имена можно скорректировать, но семантика обязательна.

## 13.1. Files

`fs.read`, `fs.write`, `fs.exists`, `fs.list`, безопасные операции только в workspace. Path traversal/symlink escape запрещены.

## 13.2. Images/networks/containers

```lua
local image = build_image {
    context = "solution",
    containerfile = "Containerfile"
}

local network = network.create({ scope = "run" })

local c = container.create({
    image = image,
    networks = { network },
    volumes = {{ host = "data", container = "/data", mode = "ro" }},
    resources = { cpu = 1.0, memory = "256m", pids = 64 }
})

c:start({
    stdin = { mode = "once", data = input_bytes },
    stdout = { mode = "realtime" },
    stderr = { mode = "realtime" }
})

local result = c:wait()
```

Handles принадлежат только текущему run. Lua не может передать сырые Podman IDs.

## 13.3. IO/Pipe

Expose `stdin_write`, `stdin_close`, `stdout_read(timeout)`, `stderr_read(timeout)`, `history`, `start_group` and PipeGraph. Точно различать EOF, timeout, peer closed и errors.

## 13.4. Time/metrics

Expose `timer.new/start/elapsed`, `sleep`, container cpu time, memory peak, exit reason and calibration factor. Timer is helper; watchdog is authoritative.

## 13.5. Reports

Expose:

```lua
report.test_started(test_id)
report.test_verdict(test_id, verdict, { score = 1.5, checker_metadata = "..." })
report.subgroup_score(subgroup_id, score, { checker_metadata = "..." })
report.problem_score(score, { checker_metadata = "..." })
report.artifact(...)
```

Build logs and stdin/stdout/stderr should be artifacts, not giant strings in gRPC messages. Invoker automatically emits `RUNNER_ERROR` with message + traceback if `runner.lua` fails.

---

# 14. Standard Executor

В Standard bundle Backend уже нормализовал Polygon package. Invoker не отвечает за Polygon import UI/ZIP parsing, но отвечает за корректное исполнение поддерживаемой Standard manifest.

Нужно предусмотреть:

- standard language definitions;
- custom languages and templates;
- Containerfile/Dockerfile support;
- author-defined build/run commands within sandbox policy;
- tests and test groups;
- validators;
- checkers (в том числе C++ `testlib.h`);
- interactors, если они заявлены поддерживаемой feature matrix;
- scoring/group rules;
- build/test logs and metrics.

Точная Polygon compatibility matrix должна быть отдельной спецификацией. Unsupported required feature -> explicit error, не молчаливое игнорирование.

Standard Executor использует общий Execution Engine. Его собственная Polygon semantics может собирать solution один раз как стандартный workflow, но **никакого такого ограничения не должно существовать для Lua scripts**.

---

# 15. Артефакты и event outbox

## 15.1. Artifacts

Артефакты загружаются через временные signed URLs/scoped grants Backend. Локальный disk spool ограничен по bytes и filesystem quota.

Kinds как минимум:

- task/source diagnostics (если разрешены);
- build log;
- runner log/traceback;
- test stdin/stdout/stderr;
- checker/interactor logs;
- custom file artifacts;
- metrics/debug artifacts.

Нельзя загружать исходный код или секреты в непредназначенные для этого artifacts.

## 15.2. Event Outbox

Перед отправкой Event сохраняется на диске с `event_id`, `sequence`, run context и fencing token. При gRPC failure повторно отправляется тем же событием. После Backend ACK файл/запись удаляется.

Не допускай, чтобы terminal event был отправлен раньше обязательных test scores/problem score или artifact upload confirmation.

---

# 16. Cancellation, lease loss, errors

Backend может отменить `run_id`. При cancel:

- немедленно завершить Lua Runner;
- остановить build operations и все containers этого run;
- закрыть IO/pipe;
- сохранить возможные artifacts;
- cleanup images/networks/workspace according ownership;
- отправить cancel/finished event.

Обычный `container:stop()` имеет 500 ms SIGTERM grace; global run cancellation имеет немедленный kill.

Если lease потерян/fencing changed, run немедленно прекращается и не может отправить валидный финальный score.

Таймаут по умолчанию 300 s. Отличать runner error, build error, timeout, OOM, output limit, Podman/API error, artifact error, backend transport error, cancellation.

---

# 17. Cleanup и Janitor

Все ресурсы маркируются labels:

```text
managed-by=podtest-invoker
podtest.invoker_id=<stable-id>
podtest.process_epoch=<epoch>
podtest.run_id=<run-id>
podtest.resource_kind=<kind>
```

Labels — для поиска/reconciliation, не security boundary.

- Каждый resource записывается в ownership registry/journal.
- Cleanup идемпотентен.
- Удалять owned containers -> networks -> temporary images.
- Не удалять общие cached/base images, используемые другими runs.
- Janitor стартует после lock/ownership check и периодически.
- Новый process не должен очистить активные ресурсы предыдущего epoch, пока не доказано, что старый process мёртв.
- Не допускать два процесса с одним invoker state directory/instance lock.
- Shared rootless Podman socket между Invoker processes одного Linux user не является межпроцессной security boundary; задокументировать это deployment ограничение.

---

# 18. Конфигурация и deployment

Поддержать config file + environment overrides. Секреты только через secret files/env injection, не хранить в исходниках и логах.

Обязательные категории конфигурации:

- identity: invoker ID, state dir;
- backend gRPC target/auth/TLS;
- NATS servers/auth/stream/consumer/subject;
- Podman socket/API family/version;
- work root/spool root;
- max active runs;
- global run timeout;
- resource hard caps;
- stdio artifact limits (512 MiB per container total как исходное значение);
- stop grace 500 ms;
- lease timings/reconnect/backoff;
- calibration benchmark/version/runs;
- telemetry/logging.

Production deployment — Linux host + rootless Podman service + dedicated `podtest-invoker` systemd service. Поставить:

- binary;
- config example;
- systemd unit;
- tmpfiles/workdir setup;
- user service/socket requirements;
- runbook for Podman socket and cgroup v2 delegation;
- health/readiness command.

Не публиковать Podman socket в сеть.

---

# 19. Observability

Structured logs с `invoker_id`, `process_epoch`, `run_id`, `attempt_id`, `submission_id`, subsystem, operation, duration and error code.

Metrics:

- active/free slots;
- NATS delivery/redelivery/claim latency;
- heartbeats/lease renew errors;
- Podman API latencies/errors;
- build duration/failures;
- container start/stop counts;
- Lua process failures/instruction limit/memory limit;
- CPU raw/normalized and calibration factor;
- memory peak/OOM;
- output bytes/limit hit;
- event spool backlog/age;
- artifact upload latency/failures;
- cleanup/janitor failures/orphan count.

Не логировать signed URLs, secrets, session credentials и полные исходники.

---

# 20. Tests

Обязательные тестовые группы:

1. Unit tests: state machine, ownership, config validation, decimal scores, event IDs/sequence, archive path handling.
2. gRPC integration tests against Go test server generated from the same proto.
3. NATS JetStream integration tests: explicit ack, NAK, redelivery, durable pull, multi-Invoker worker distribution.
4. Podman integration tests using rootless socket: build, create, start, attach, inspect, stop, kill, wait, remove.
5. Resource tests: RAM/OOM, CPU, PIDs, wall timeout, disk/output caps.
6. Network tests: runtime `none`, internal task network isolation, build egress policy.
7. Lua tests: isolated process, sandbox denial, instruction limit, memory limit, RPC ownership, coroutine IO.
8. Pipe tests: bidirectional cycle, bounded buffers, backpressure, EOF and early termination.
9. Artifact tests: download checksum, presigned upload, interrupted upload/retry, disk spool recovery.
10. Crash recovery tests: kill Invoker after Claim, during build, during run, after Event write but before ACK; verify lease fencing and cleanup.
11. End-to-end: create a task package + solution, run both `standard` and `scripted_lua`, persist test verdicts and base score in a Backend test server, cleanup all Podman resources.

Mocks are allowed for unit tests, but integration/acceptance must use actual NATS, actual Go gRPC test server, and actual rootless Podman where CI supports it. Clearly mark skipped environment-dependent tests; do not claim they passed.

---

# 21. Implementation phases

Не пытайся реализовать всё одновременно. В конце каждого этапа оставляй рабочую сборку и тесты.

## Phase 0 — technical spikes and ADRs

- inspect actual Zig version;
- verify gRPC/protobuf approach;
- verify `nats.zig`/alternative with JetStream pull+ack;
- verify Podman Unix socket HTTP client;
- propose final protocol additions for Cancel/Lease/Artifact upload;
- write ADRs and compatibility matrix.

## Phase 1 — process skeleton

- config and validation;
- logging/metrics/health;
- systemd unit;
- stable instance ID + process epoch + exclusive lock;
- unit tests.

## Phase 2 — control plane

- NATS durable pull consumer;
- Heartbeat;
- Claim;
- lease handling;
- gRPC Report with persistent event spool;
- cancel command channel (or agreed equivalent);
- mock Go backend integration tests.

## Phase 3 — Workspace/artifacts

- signed URL download, descriptor pinning and SHA-256 verification (implemented; PostgreSQL/mTLS/HTTPS MinIO acceptance passed);
- secure USTAR unpack and atomic bundle/source publication (implemented and integration-tested);
- logical workspace/spool limits (implemented; provision a host filesystem quota in deployment);
- Backend-scoped S3 upload grants, durable intents/receipts and restart recovery (implemented; lost completion response/restart acceptance passed);
- receipt-gated result outbox API (implemented/tested as a component; production Report/event encoder is not connected);
- execution and judging are NOT enabled: JetStream claim/scheduler, sandbox runner, runtime capability negotiation and production Heartbeat/Report remain acceptance gates; keep `execution_ready: false`.

## Phase 4 — Podman Adapter

- Unix socket transport;
- API version compatibility;
- image build/inspect;
- network create/remove;
- container create/start/inspect/stop/kill/wait/remove;
- streaming build/logs.

## Phase 5 — Resource and IO Engine

- cgroup metrics/limits;
- OOM classification;
- wall-time watchdog;
- stdio modes;
- disk-backed history;
- pipe graph and backpressure;
- cancellation and cleanup.

## Phase 6 — Lua process

- process sandbox;
- local RPC;
- Lua 5.5 embedding;
- safe module loader;
- instruction/memory limits;
- coroutine scheduler and yieldable APIs;
- scripted_lua end-to-end fixture.

## Phase 7 — Standard Executor

- normalized Polygon bundle contract;
- languages/build/run config;
- tests/checker/interactor/scoring supported subset;
- end-to-end Standard task.

## Phase 8 — Hardening

- janitor/crash recovery;
- concurrent Invoker tests;
- load tests;
- threat tests;
- performance calibration;
- docs and release package.

---

# 22. Code quality and engineering rules

## Zig

- Use explicit allocators and document ownership/lifetimes.
- Every heap allocation has a clear owner/deinit path.
- Do not use global mutable state for per-run data.
- Errors must be typed and contextual; no swallowed errors.
- All external IO has deadlines/cancellation where possible.
- Do not leak file descriptors, sockets, subprocess handles or Podman resources.
- Keep modules small and testable.
- Pin dependencies and compiler version.
- Build in Debug and ReleaseSafe/ReleaseFast as appropriate; do not assume one optimization mode.

## Security

- Fail closed on unknown execution format/API version/manifest required feature.
- Never accept raw Podman IDs/JSON from Lua.
- Never expose Podman socket to Lua/solution containers.
- Never trust archive paths, env variables or Containerfile.
- Enforce run owner on every resource handle/RPC.
- Never allow runtime internet unless a distinct approved requirement is added.
- Do not treat labels as authorization.
- Bound all queues, streams, artifacts, files, containers, coroutines, memory and times.

## Compatibility

- Use `control.proto` as source of wire contract and keep Go interop tests.
- Add fields backward-compatibly.
- The `openapi.yaml` public REST contract is not the Invoker protocol.
- If a required contract change cannot be implemented without Backend changes, write the proposed `.proto` and mock server tests, document the integration blocker, and do not fake remote success.

---

# 23. Required deliverables

1. New independent Zig project `podtest-invoker` (or agreed repository path); old project untouched.
2. `build.zig`, `build.zig.zon`, pinned dependencies and compiler compatibility note.
3. Working `podtest-invoker` binary.
4. Config file schema and example.
5. gRPC generated bindings/client and updated `.proto` proposal (if required).
6. NATS JetStream client integration.
7. Podman Libpod API adapter over Unix socket.
8. Execution Engine modules.
9. Standard Executor for agreed initial Polygon subset.
10. Lua Runner child process and local RPC.
11. Lua API v1 documentation and sample `runner.lua` tasks.
12. Workspace, artifact spool, event outbox, cleanup and janitor.
13. systemd unit and deployment/runbook.
14. Unit, integration, security and end-to-end tests.
15. `docs/architecture.md`, `docs/control-api.md`, `docs/lua-api.md`, `docs/bundle-format.md`, `docs/deployment.md`.
16. A list of unsupported Polygon features and open decisions.

---

# 24. Неизменяемые ограничения задачи агенту

- Не модифицировать `~/programming/podtestInvokerOld`.
- Не переписывать Backend/Frontend в рамках реализации Invoker.
- Не добавлять новые встроенные execution formats кроме `standard` и `scripted_lua`.
- Не делать обязательное правило «одна сборка на submission» для Lua.
- Не давать Lua прямой доступ к Podman, Backend credentials, NATS credentials или PostgreSQL.
- Не позволять тестируемым контейнерам runtime Internet access.
- Не использовать Docker socket/CLI вместо согласованного Podman API.
- Не отправлять большие артефакты в protobuf/NATS messages.
- Не считать event/JetStream delivery exactly-once; реализовать idempotency.
- Не считать process separation единственным механизмом sandbox.
- Не заявлять абсолютную независимость CPU timing от hardware; raw and normalized metrics должны сосуществовать.
- Не объявлять end-to-end test успешным, если он запускался только на mock Podman.

---

# 25. Ожидаемый первый ответ агента

До начала большой реализации представь:

1. подтверждённую версию Zig и Podman;
2. краткий разбор текущего `control.proto` и список недостающих RPC/fields;
3. выбор NATS Zig client с проверенной JetStream feature matrix;
4. выбор gRPC/Protobuf implementation и результат минимального Go↔Zig interop spike;
5. список рисков/блокеров;
6. план вертикальных реализационных этапов;
7. перечень файлов старого проекта, которые были изучены read-only (если он был доступен), с явным подтверждением, что старый проект не менялся.

После этого переходи к Phase 1 и не пытайся сделать весь проект одним гигантским коммитом.
