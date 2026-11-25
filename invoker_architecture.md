# podtest Invoker — подробная архитектура

**Статус:** проектная спецификация, основанная на согласованной архитектуре podtest, исходном плане старого Invoker, текущем `control.proto` и Backend OpenAPI.

**Назначение:** определить архитектуру нового Invoker, который исполняет judging attempts, управляет Podman, поддерживает Polygon Standard и Scripted Lua, безопасно работает с несколькими экземплярами и обменивается заданиями/событиями с Backend.

> В документе используются пометки:
>
> - **Принято** — требование явно согласовано.
> - **Предлагаемая реализация** — рекомендуемая техническая реализация принятого требования.
> - **Открыто** — решение необходимо подтвердить до соответствующей реализации.
> - **Не делать** — устаревшая или отвергнутая идея.

---

# 1. Назначение и границы ответственности

## 1.1. Назначение

Invoker — исполнительная часть тестирующей системы **podtest**. Он получает задания на проверку решений, загружает неизменяемые артефакты конкретной ревизии задачи и посылки, запускает предусмотренный формат исполнения, собирает результаты и возвращает их Backend.

Invoker должен поддерживать два встроенных формата:

1. **`standard`** — встроенное исполнение Polygon-задач.
2. **`scripted_lua`** — исполнение пользовательского `runner.lua`, который определяет произвольную последовательность сборок, запусков, тестов, сервисов и checker-процессов через ограниченный API.

HTTP, SQL, run-twice, интерактивные схемы и другие нестандартные способы тестирования не являются отдельными встроенными форматами. Они реализуются Lua-сценариями и готовыми Lua-библиотеками.

## 1.2. Место Invoker в podtest

Backend — источник истины о пользователях, задачах, ревизиях, посылках, judging attempts, вердиктах, базовых баллах, Grader и опубликованных оценках.

Invoker:

- не управляет пользователями, курсами и контестами;
- не решает, имеет ли пользователь право отправить решение;
- не выбирает итоговую оценку участника по истории его посылок;
- не имеет прямого доступа к PostgreSQL;
- не имеет прямого доступа к OpenFGA;
- не выставляет оценки в scoreboard напрямую;
- исполняет конкретный judging attempt и сообщает Backend наблюдения/результаты этого исполнения.

Lua/Standard Executor выставляет **базовую оценку конкретной посылки**. Отдельная подсистема Grader в Backend может вычислить итоговую оценку участника на основании множества посылок того же или других участников. Grader не входит в Invoker и не изменяет judging results.

## 1.3. Ключевые принципы

1. В системе может работать несколько Invoker-ов, в том числе на разных хостах.
2. Все Invoker-ы реализуют один протокол и поддерживают оба формата исполнения.
3. Backend распределяет задания между Invoker-ами через NATS JetStream.
4. gRPC используется для claim/lease, heartbeat, событий исполнения, артефактных разрешений и команд управления.
5. Архивы и большие артефакты передаются через S3-compatible storage, а не в сообщениях NATS/gRPC.
6. Один judging attempt привязан к неизменяемой ревизии задачи и конкретной посылке.
7. Каждый фактический запуск имеет отдельный `run_id`; `judging_attempt_id` и `run_id` — разные идентификаторы.
8. Все операции с Podman выполняет основной процесс Invoker через Podman REST API на Unix socket.
9. Lua Runner запускается отдельным процессом на каждый `scripted_lua` attempt и не получает Podman socket или Backend credentials.
10. Standard Executor и Lua Runner используют один Execution Engine.
11. Lua определяет порядок и количество сборок/запусков. Запрещено навязывать общему `scripted_lua` правилу «собрать решение один раз на посылку и использовать на всех тестах».
12. Invoker обеспечивает изоляцию, ресурсные лимиты, таймауты, сбор метрик, артефакты, отмену и очистку.
13. Результаты должны быть идемпотентно доставлены Backend; повторная доставка события не должна повторно применить результат.

## 1.4. Терминология

| Термин | Значение |
|---|---|
| Invoker instance | Один зарегистрированный экземпляр Invoker на хосте/среде выполнения |
| `invoker_id` | Стабильный ID экземпляра, зарегистрированный Backend |
| `process_epoch` | Уникальный ID текущего процесса Invoker; меняется после перезапуска |
| Submission | Неизменяемая отправка участника |
| JudgingAttempt | Логическая попытка проверки Submission на конкретной ProblemRevision |
| Run | Фактическое исполнение JudgingAttempt на одном Invoker; имеет `run_id` и fencing token |
| Task bundle | Неизменяемый пакет ревизии задачи для Invoker |
| Solution artifact | Архив/файлы конкретной посылки |
| Executor | Компонент, реализующий формат `standard` или `scripted_lua` |
| Execution Engine | Низкоуровневые менеджеры образов, контейнеров, сетей, IO, ресурсов, метрик и артефактов |
| Lua Runner | Отдельный процесс, запускающий `runner.lua` и обращающийся к Execution Engine через локальный RPC |
| Artifact | Build log, stdout/stderr/stdin history, trace, файл или другой результат исполнения |
| Handle | Непрозрачная ссылка на ресурс, созданный в конкретном run |

---

# 2. Технологический стек и окружение

## 2.1. Язык и платформа

**Принято из предыдущего обсуждения:**

- Язык Invoker: Zig.
- В локальном окружении пользователя `zig version` показывал `0.17.0`; пакет Arch/pacman назывался `0.17.0-1.1`.
- Платформа: Linux, x86-64.
- Lua: 5.5.
- Разрешены библиотеки, совместимые с зафиксированной версией Zig.

**Важно по версии Zig:** на дату этой редакции официальный сайт Zig уже публикует 0.17.1 как стабильную версию. Это не означает автоматического изменения целевого toolchain podtest. Агент не должен самостоятельно обновлять компилятор: сначала проверить фактически установленную версию (`zig version`), зафиксировать её в CI/документации и проверить все зависимости на ней. Если проект решит перейти на 0.17.1, это отдельное осознанное изменение.

Ссылки: [Zig 0.17.0 release](https://ziglang.org/news/0.17.0-released/), [Zig 0.17.1 release](https://ziglang.org/news/0.17.1-released/), [официальные загрузки и stable version](https://ziglang.org/download/).

## 2.2. Container runtime

- Podman rootless.
- Взаимодействие только через HTTP REST API по Unix domain socket; не вызывать `podman` CLI как runtime-механизм.
- Путь к socket конфигурируемый. Исходный default из проекта: `/run/user/1000/podman/podman.sock`.
- Предпочтительно получать путь по `XDG_RUNTIME_DIR` (`$XDG_RUNTIME_DIR/podman/podman.sock`), если он задан; явный конфиг имеет приоритет.
- Использовать Podman-native Libpod API там, где это необходимо; не смешивать бессистемно Docker compatibility API и Libpod API.
- Версия Podman/API фиксируется в deployment matrix и проверяется на старте.

Podman предоставляет два слоя REST API: Docker-compatible и native Libpod; API обслуживается `podman system service`, поддерживает systemd socket activation и rootless socket под `$XDG_RUNTIME_DIR`. См. [Podman system service](https://docs.podman.io/en/latest/markdown/podman-system-service.1.html) и [Libpod API reference](https://docs.podman.io/en/latest/_static/api.html).

**Безопасность:** Podman socket фактически даёт основному Invoker широкие права управления контейнерным окружением. Socket нельзя передавать Lua Runner или внутрь тестируемых контейнеров. Его доступ должен иметь только доверенный основной Invoker.

## 2.3. gRPC и Protocol Buffers

- Backend реализован на Go; для него генерируются Go stubs из `control.proto`.
- Invoker реализован на Zig и должен реализовать совместимый gRPC client.
- Protobuf не сериализовать вручную ad-hoc форматом.
- Библиотеку gRPC/Protobuf необходимо проверить на точном Zig toolchain и совместимость с Go gRPC сервером до реализации всего runtime.

У экосистемы Zig нет официального gRPC implementation от grpc.io; существуют варианты через официальный gRPC C core и сторонние Zig-проекты. Предпочтительный вариант для production — `libgrpc` C core через Zig C interop + проверенный Protobuf codegen/runtime, если сборка и deployment приемлемы. Чисто-Zig библиотеку разрешено использовать только после полноценного interoperability test: unary RPC, TLS/mTLS, metadata, deadlines, статус-коды, reconnect и совместимость с Go server. Не писать собственную неполную реализацию HTTP/2/gRPC как побочный проект.

Возможные отправные точки для исследования: [gRPC C core](https://github.com/grpc/grpc), [zig-protobuf](https://github.com/Arwalk/zig-protobuf). Совместимость конкретных версий должна быть проверена агентом; ссылка сама по себе не является одобрением зависимости.

## 2.4. NATS JetStream

Invoker использует durable pull consumer. Backend публикует задание, а Invoker запрашивает его только при наличии свободного execution slot. Для работы, которую нельзя потерять, используется explicit acknowledgement; JetStream повторно доставляет сообщение, если подтверждение не получено в допустимое время. См. [JetStream consumers](https://docs.nats.io/nats-concepts/jetstream/consumers), [pull consumers](https://docs.nats.io/learn/jetstream/pull-consumers), [acknowledgements](https://docs.nats.io/jetstream/concepts/acknowledgements).

В Zig существует клиент [nats-io/nats.zig](https://github.com/nats-io/nats.zig), который заявляет core NATS и JetStream pull consumers. По текущему README он pre-1.0, активно развивается; перед использованием нужно проверить конкретную версию, JetStream ack/reconnect semantics, TLS/auth и совместимость с зафиксированным Zig. В его текущей заявленной feature matrix mTLS ещё не реализован. Это предпочтительный кандидат для spike, но не автоматический выбор production dependency.

Конкретные stream/subject/consumer names и NATS credentials задаются конфигурацией, а не хардкодятся.

## 2.5. S3-compatible storage

- Task bundle, solution artifact и большие логи/stdio хранятся в S3-compatible storage.
- Invoker получает временные URL/credentials, ограниченные конкретным объектом и операцией.
- Не встраивать общие MinIO credentials с правом чтения/записи всех объектов в Lua Runner.
- После загрузки всегда проверять SHA-256 и размер.

---

# 3. Логическая архитектура Invoker

## 3.1. Компоненты процесса

```text
                     Backend
                       ^  |
             gRPC events|  |control/claim/lease
                       |  v
                +--------------+
                | Invoker Core |
                |  Zig process |
                +------+-------+
                       |
             NATS pull consumer
                       |
               +-------v-------+
               | Run Supervisor|
               +-------+-------+
                       |
        +--------------+----------------+
        |                               |
+-------v--------+              +-------v--------+
| Standard       |              | Lua Runner     |
| Executor       |              | Manager        |
| (Polygon)      |              +-------+--------+
+-------+--------+                      |
        |                        local RPC / UDS
        |                               |
        |                        +------v------+
        |                        | Lua Runner  |
        |                        | process     |
        |                        +------+------+
        |                               |
        +---------------+---------------+
                        |
                Execution Engine
                        |
      +-----------------+--------------------+
      |       |        |        |       |     |
    Image  Container Network   IO     Resource Metrics
   Manager Manager  Manager  /Pipe  Manager Manager
      |       |        |        |       |     |
      +-------+--------+--------+-------+-----+
                        |
                 Podman REST API
                   Unix socket
                        |
              isolated task containers

Artifact Spooler + Event Outbox are cross-cutting components.
Janitor/Cleanup Manager operates on all owned resources.
```

## 3.2. Основные подсистемы

| Подсистема | Ответственность |
|---|---|
| `InvokerCore` | Конфигурация, startup/shutdown, жизненный цикл процесса |
| `NatsConsumer` | Получение job advertisements из JetStream |
| `BackendControlClient` | Heartbeat, Claim, lease, Report, command subscription, artifact grants |
| `RunSupervisor` | Создание и управление run, state machine, cancellation, timeouts |
| `ArtifactDownloader` | Загрузка task bundle и solution artifact по подписанным URL |
| `WorkspaceManager` | Уникальные каталоги, безопасная распаковка, quota, cleanup |
| `StandardExecutor` | Исполнение Polygon Standard task |
| `LuaRunnerManager` | Запуск и надзор отдельного Lua process |
| `LuaRpcServer` | Ограниченный локальный API Execution Engine для Lua process |
| `ExecutionEngine` | Общая инфраструктура исполнения |
| `PodmanClient` | HTTP client поверх Unix socket и Podman API |
| `ResourceManager` | CPU/RAM/PIDs/disk/time/output limits, cgroup наблюдение |
| `MetricsManager` | Raw/normalized CPU, wall time, memory peak, OOM и др. |
| `ArtifactSpooler` | Локальное disk-backed накопление и загрузка артефактов |
| `EventOutbox` | Надёжная локальная очередь недоставленных событий |
| `CleanupManager` | Удаление ресурсов и workspace в любом исходе |
| `Janitor` | Восстановление после падения Invoker и удаление orphan resources |
| `HealthReporter` | Heartbeat, capacity, liveness/readiness и диагностические статусы |

Эти подсистемы — модули одного Zig-процесса, за исключением Lua Runner, который является отдельным дочерним процессом на run.

## 3.3. Развёртывание и несколько Invoker-ов

В podtest может быть несколько Invoker-ов на разных Linux-хостах. Backend направляет задание через общую JetStream очередь, все Invoker-ы используют один durable pull consumer/consumer group, а Claim предотвращает двойное владение attempt.

Каждый экземпляр имеет:

- `invoker_id` — стабильный ID, зарегистрированный в Backend;
- `process_epoch` — новый UUID при каждом запуске процесса;
- отдельный work root;
- отдельный локальный event spool;
- собственный config и Podman socket;
- собственный лимит concurrent runs.

Invoker предпочтительно устанавливается как host service под отдельным Linux-пользователем и запускается через systemd user/system unit. Это проще и безопаснее, чем давать контейнеру Invoker доступ к host Podman socket. Контейнерное развёртывание возможно как отдельный вариант, но mount Podman socket в контейнер Invoker считается привилегированным доступом и требует отдельного threat review.

Invoker не является частью центрального `podman-compose` stack Backend/Frontend по умолчанию: он может располагаться на отдельной машине и должен общаться с NATS/Backend/S3 по защищённой сети. Центральный podtest stack использует Podman Compose; execution hosts устанавливаются как отдельные узлы Invoker Fleet.

---

# 4. Job delivery: NATS + Claim + lease

## 4.1. Разделение NATS и gRPC

**NATS JetStream** сообщает Invoker-у, что появился job. Он не является единственным источником права выполнять job.

**gRPC `Claim`** атомарно подтверждает, что конкретный Invoker получил право выполнить конкретный `run_id` для конкретного `judging_attempt_id`.

Задание содержит metadata и идентификаторы; архивы не передаются в NATS message.

## 4.2. Рекомендуемый NATS job message

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

Идентификаторы ревизии/посылки должны совпадать с теми, что хранятся в Backend. `run_id` уникален для конкретной выдачи execution lease. `judging_attempt_id` обозначает логическую проверку.

Не помещать signed URLs в долговечное сообщение очереди: claim выдаёт свежие короткоживущие URL.

## 4.3. Цикл получения

1. Invoker сообщает heartbeat и capacity.
2. При наличии свободного slot NATS consumer делает pull (не получать больше сообщений, чем можно обработать).
3. Получив job advertisement, Invoker вызывает `Control.Claim(invoker_id, attempt_id, run_id)`.
4. Backend атомарно проверяет состояние attempt, принадлежность run, текущий lease/fencing и право назначения.
5. Если claim принят, Backend возвращает lease и временные URL на source artifact и task bundle (а также digests/sizes/limits).
6. После успешного claim NATS message подтверждается ACK. Дальнейший recovery выполняется по Backend lease, а не за счёт бесконечной redelivery одного NATS message.
7. Если Claim временно недоступен из-за network/backend error — NAK с задержкой или не ACK; повторная доставка допустима.
8. Если Backend сообщает, что run уже claimed/terminal/stale/cancelled — message ACK и игнорируется как устаревший.

JetStream pull consumer следует настроить с explicit ack, bounded pending и подходящими `AckWait`/backoff/MaxDeliver. Не загружать задания при отсутствии свободных run slots. В документации NATS explicit ack обеспечивает повторную доставку неподтверждённых сообщений; consumer/client должны учитывать redelivery и идемпотентность.

## 4.4. Lease и fencing

Lease защищает от ситуации, когда старый Invoker потерял связь, Backend назначил run повторно, но старый процесс неожиданно продолжил работу.

ClaimResponse должен содержать:

- `lease_expires_unix` или `lease_expires_at`;
- `lease_token` либо монотонный `fencing_token`;
- источник/solution signed URL;
- bundle signed URL;
- SHA-256 и размер каждого объекта;
- лимиты и execution metadata, если они не извлекаются из immutable bundle.

Invoker регулярно вызывает `RenewLease` или отправляет heartbeat с активными run IDs. Backend отклоняет события со stale fencing token. При потере lease Invoker немедленно прекращает соответствующий run и cleanup.

При аварии Invoker Backend может повторно выдать выполнение. Старые события не должны приниматься после нового fencing token. Предлагаемая модель: новый фактический `run_id`/generation при повторной выдаче; старый run сохраняется в audit/debug метаданных, но его события больше не меняют judging result.

## 4.5. Concurrency

Invoker поддерживает несколько одновременных judging attempts. Значение `max_active_runs` настраивается в конфиге и сообщается в Heartbeat. На первом этапе допустимо выставить небольшой лимит и увеличивать его после load/security testing.

Поддержка нескольких runs на одном Invoker не означает, что Standard Executor обязан выполнять тесты одной посылки параллельно. Для Standard начальная политика — последовательное исполнение тестов; Scripted Lua сам управляет конкурентностью контейнеров/тестов в пределах resource budget. Общее ограничение на параллельное исполнение внутри Lua — лимиты конкретного run.

---

# 5. Backend gRPC contract и текущий `control.proto`

## 5.1. Текущая заготовка

В предоставленном `control.proto` сейчас определены:

```proto
service Control {
  rpc Heartbeat(HeartbeatRequest) returns (Acknowledgement);
  rpc Claim(ClaimRequest) returns (ClaimResponse);
  rpc Report(Event) returns (Acknowledgement);
}
```

В `HeartbeatRequest` уже есть `invoker_id`, `protocol_version`, `execution_formats`, `capacity`, `load`.

В `ClaimRequest` есть `invoker_id`, `attempt_id`, `run_id`.

`ClaimResponse` содержит `lease_expires_unix`, `source_url`, `bundle_url`.

`Event` содержит `event_id`, `attempt_id`, `run_id`, `submission_id`, `invoker_id`, `sequence`, `schema_version`, `occurred_at_unix_millis`, `kind`, `verdict`, optional string `score`, `test_id`, `subgroup_id`, `artifact_id`. Enum включает Run/Build/Test/Subgroup/Problem/Artifact/Error/Timeout/Cancelled/Finished события.

Это хорошая компактная начальная заготовка. Она совместима с pull-моделью, отделяет claim от доставки job и не передаёт архивы по gRPC.

## 5.2. Недостающие элементы текущего proto

Перед production реализацией контракт необходимо дополнить или согласовать альтернативные механизмы для следующих функций:

1. **Отмена run.** Текущий `Control` не содержит метода, по которому Invoker получает команды Backend. Добавить server-streaming `WatchCommands` либо определить отдельный NATS control subject. Рекомендуется gRPC `WatchCommands`.
2. **Продление lease.** Heartbeat можно расширить списком active runs, но явный `RenewLease` проще валидировать и дебажить.
3. **Fencing.** В ClaimResponse и Report event должны присутствовать lease/fencing token/generation, чтобы старый Invoker не мог отправлять результаты после повторного назначения.
4. **Artifact upload grants.** Текущий `artifact_id` не объясняет, как Invoker получает ограниченное право загрузить файл в S3. Добавить RPC `CreateArtifactUpload` или эквивалентный Backend API выдачи presigned PUT/multipart URLs.
5. **Digest и size.** `source_url`/`bundle_url` должны сопровождаться SHA-256 и ожидаемым размером.
6. **Heartbeat.** Поля `capacity` и `load` надо формально определить: total slots, free slots, active runs; желательно передавать active run IDs и `process_epoch`.
7. **Семантика ACK.** `Acknowledgement` сейчас содержит только `duplicate`. Нужно определить, что ACK означает «событие атомарно принято и сохранено/поставлено на обработку», а duplicate означает «это событие уже было успешно принято».
8. **Event payload.** Общие поля удобны для первой версии, но для новых типов лучше постепенно ввести `oneof`-payload, чтобы невозможные комбинации полей нельзя было отправить.
9. **Build log chunk.** `BUILD_LOG_CHUNK` не содержит содержимое чанка. Большие логи не должны передаваться в `Event` целиком; загружать их в artifact storage и отправлять `ARTIFACT_CREATED` с artifact metadata.
10. **Run finish status.** `RUN_FINISHED` должен содержать outcome, а не полагаться только на предшествующие события.

Изменение номера поля существующего protobuf запрещено. Новые поля добавлять с новыми field numbers; удалённые номера резервировать. Контракт должен иметь версионирование и compatibility tests.

## 5.3. Рекомендуемые расширения Control service

Рекомендуемый логический контракт:

```proto
service Control {
  rpc Heartbeat(HeartbeatRequest) returns (Acknowledgement);
  rpc Claim(ClaimRequest) returns (ClaimResponse);
  rpc RenewLease(RenewLeaseRequest) returns (RenewLeaseResponse);
  rpc Report(Event) returns (Acknowledgement);
  rpc WatchCommands(WatchCommandsRequest) returns (stream Command);
  rpc CreateArtifactUpload(CreateArtifactUploadRequest)
      returns (ArtifactUploadTarget);
}
```

`WatchCommands` получает как минимум `CancelRun` (attempt_id, run_id, fencing token, reason, issued_at). Команда отмены идемпотентна.

`CreateArtifactUpload` возвращает `artifact_id`, object key, временный upload URL/список multipart URLs, expiry и обязательные headers. Invoker не получает общий S3 access key.

Это предложение по расширению загруженного proto, а не уже существующий Backend контракт. Перед генерацией stubs Backend и Invoker должны согласовать конечный `.proto` в одном репозитории/контрактном пакете.

## 5.4. Event semantics

Каждое событие содержит:

- `event_id`: UUID; в `bytes` поле protobuf — ровно 16 байт, если выбран binary UUID;
- `attempt_id`, `run_id`, `submission_id`, `invoker_id`;
- `sequence`: строго возрастающий в пределах `run_id`;
- `fencing_token`/execution generation;
- `schema_version`;
- `occurred_at_unix_millis`;
- `kind` и соответствующий payload.

Invoker создаёт событие один раз и повторно отправляет его с тем же `event_id` и sequence до ACK. Sequence нельзя выдавать заново после перезапуска процесса; он должен быть сохранён вместе с локальным event spool.

Backend проверяет run ownership, fencing token, sequence policy, ID тестов/подгрупп, конечность и диапазон scores, допустимость события по state machine и отсутствие событий после terminal state.

## 5.5. Score representation

Пользователь ранее назвал тип балла `float`, но `control.proto` уже передаёт `score` как optional decimal string с комментарием про точность до 6 знаков после запятой. Рекомендуется сохранить wire representation строкой, а в Backend/DB использовать PostgreSQL `NUMERIC`, не IEEE-754 binary float. Lua API может принимать number, но сериализатор должен преобразовывать конечное число в каноническую decimal string; `NaN`/Infinity запрещены. Нужно согласовать rounding/max scale и максимальный диапазон с Backend.

---

# 6. Task bundle, solution artifact и workspace

## 6.1. Содержимое задания

Backend передаёт ссылки на два независимых объекта:

- `bundle_url` — immutable task revision bundle;
- `source_url` — source/solution artifact для конкретной Submission.

Bundle должен содержать `manifest.json`, execution files, тесты/ресурсы (для Standard) либо `runner.lua` и файлы Lua-задачи (для Scripted Lua). Описание точной нормализованной структуры bundle должно быть отдельным versioned контрактом.

Invoker не выполняет Polygon import. Backend ProblemManager отвечает за импорт ZIP/API, совместимость, нормализацию и публикацию immutable revision. Invoker получает уже подготовленный execution bundle.

## 6.2. Workspace layout

Рекомендуемый layout:

```text
<work_root>/<invoker_id>/runs/<run_id>/
  metadata/
    run.json
    manifest.json
  task/
    ... task bundle files ...
  solution/
    ... unpacked solution artifact ...
  tmp/
    ... build contexts / transient files ...
  spool/
    ... pending event and artifact upload state ...
  lua/
    runner.lua
    ipc.sock
```

Конкретный layout может отличаться, но все файлы одного run должны находиться в отдельном уникальном root и иметь проверяемое владение.

## 6.3. Download and verification

1. Получить ClaimResponse с временными URL.
2. Скачать каждый объект потоково на диск с верхними лимитами размера.
3. Проверить HTTP status, content length/observed length и SHA-256.
4. Проверить, что format/version соответствует заявлению job.
5. Только после проверки распаковать.
6. При любой ошибке удалить временный файл и завершить run как infrastructure/package error.

URL должны иметь короткий срок действия, быть привязаны к одному объекту и только к требуемому методу. Запрещено логировать полный signed URL.

## 6.4. Безопасная распаковка

При обработке tar/zip архивов обязательны:

- запрет абсолютных путей;
- запрет `..` path traversal;
- запрет symlink/hardlink, выводящих за пределы root;
- запрет block/character devices, FIFO и сокетов;
- лимит числа файлов;
- лимит глубины директорий;
- лимит размера каждого файла и суммарного распакованного размера;
- защита от zip bomb/compression bomb;
- нормализация имен и запрет дублирующихся путей/конфликтов регистра там, где это важно;
- безопасное создание файлов без перезаписи родительских ссылок;
- path resolution относительно directory file descriptor, предпочтительно с `openat2` и `RESOLVE_BENEATH`/запретом magic links/symlinks или эквивалентной race-safe реализацией.

Строковая проверка `../` сама по себе не достаточна.

## 6.5. Формат архива

**Открыто:** точный wire-format task bundle и solution archive должен быть согласован с Backend. Рекомендуется выбрать один canonical archive format с manifest, digest и версией (например, tar + zstd или tar + gzip) и не определять формат угадыванием по расширению. Polygon ZIP и Scripted package ZIP, поступающие в Backend, не обязаны быть тем же форматом, который Backend выдаёт Invoker-у.

---

# 7. Execution Engine

## 7.1. Назначение

Execution Engine — единый низкоуровневый слой, используемый и Standard Executor, и Lua API. Он не знает бизнес-логики оценки и не решает, какой тест запускать следующим.

Подсистемы:

| Manager | Задачи |
|---|---|
| `ImageManager` | Build image, image identity/digest, cache references, remove owned image |
| `ContainerManager` | Create/start/stop/kill/wait/inspect/remove container |
| `NetworkManager` | Create/inspect/remove task-private networks |
| `VolumeManager` | Разрешить безопасные host mounts только из workspace, задавать ro/rw |
| `IOManager` | stdin/stdout/stderr, once/realtime/none, spool |
| `PipeManager` | Соединение потоков контейнеров, bounded buffers, backpressure, EOF |
| `ResourceManager` | Применение CPU/RAM/PIDs/disk/time/output/network limits |
| `MetricsManager` | CPU time, normalized score, memory peak, OOM, exit reason |
| `ArtifactManager` | Local spool, S3 upload, artifact metadata |
| `OwnershipRegistry` | Handles/resources/run ownership, cleanup journal |

## 7.2. Podman HTTP client

- Использовать HTTP transport, который поддерживает Unix domain socket.
- Все Podman endpoints сосредоточить в одном `PodmanClient`/adapter.
- Использовать Podman Libpod API schema для закреплённой версии Podman.
- HTTP keep-alive/connection pooling разрешён, но API operations должны иметь deadlines/cancellation.
- Ответы Podman и API errors преобразуются в типизированные внутренние ошибки.
- Стримы build/attach/log не должны буферизоваться целиком в RAM.
- Не передавать arbitrary Podman request JSON из Lua напрямую.
- Не вызывать CLI для обхода недостающего API endpoint. Если какой-то API capability отсутствует — явно задокументировать ограничение или выбрать контролируемый альтернативный путь.

## 7.3. Handles и ownership

Lua получает непрозрачные handles `Image`, `Network`, `Container`, `Timer`, `PipeGroup`, `Artifact`. Handle не содержит подставляемый пользователем Podman ID.

Каждый ресурс связан с:

- `invoker_id`;
- `process_epoch`;
- `run_id`;
- внутренним Podman resource ID;
- типом ресурса;
- состоянием lifecycle;
- cleanup policy.

Перед каждой операцией проверять run ownership и lifecycle. Использование handle из другого Lua Runner/run — ошибка.

Podman labels для диагностики и reconciliation:

```text
managed-by=podtest-invoker
podtest.invoker_id=<stable-id>
podtest.process_epoch=<epoch>
podtest.run_id=<run-id>
podtest.resource_kind=image|container|network|build
```

Labels не являются security boundary: их можно подделать. Реальная изоляция обеспечивается процессными правами, Podman trust boundary, ownership registry и корректной очисткой.

## 7.4. Image build

Lua может вызывать `build_image` сколько угодно раз в пределах run budget. Invoker не навязывает количество сборок и не требует собирать решение один раз.

Пример API-идеи:

```lua
local image = build_image {
    context = "solution",
    containerfile = "Containerfile",
    build_args = {},
    network = "task_build_egress"
}
```

Требования:

- context path строго внутри workspace;
- Containerfile/Dockerfile может быть в разрешённой поддиректории;
- build args валидируются; секреты не попадают в обычные логи;
- build network отделён от runtime network;
- сеть при сборке разрешена, поскольку автор задачи задаёт зависимости;
- build-time egress не должен предоставлять host network, доступ к Podman socket, локальным сервисам хоста или runtime сетям других runs;
- время, CPU, RAM, disk и размер build output ограничиваются;
- сборка отменяется при отмене run;
- build log потоково сохраняется как artifact;
- image получает owner metadata и возвращается как opaque handle;
- кеширование допустимо только при digest-complete cache key; кеш не меняет семантику сценария.

Podman build имеет собственный `--network` для `RUN` инструкций. Host network даёт доступ к локальным сервисам хоста и не должен использоваться как штатный build режим. См. [Podman build reference](https://docs.podman.io/en/latest/markdown/podman-build.1.html).

## 7.5. ContainerSpec

Не открывать все поля Podman API. Внутренний `ContainerSpec` должен иметь allowlist безопасных опций:

- image handle;
- command/args, env allowlist/size limits;
- working directory;
- user/uid/gid;
- networks — только handles текущего run;
- mounts — только безопасные paths в workspace или managed tmpfs;
- CPU quota/cpuset при разрешении;
- memory limit;
- swap policy (по умолчанию отключить swap для test containers);
- PID limit;
- disk/workspace quota;
- wall-clock timeout;
- read-only rootfs по умолчанию, с отдельными writable mounts;
- `no-new-privileges`;
- минимальный набор Linux capabilities;
- seccomp profile;
- no devices;
- отсутствие host pid/ipc/network namespaces;
- явный network mode.

Запрещены privileged mode, arbitrary host mounts, Podman socket mounts, host network, host PID/IPC, произвольные device mappings, dangerous capabilities и namespace-sharing с чужими runs.

## 7.6. Container lifecycle

Контейнер — одноразовый handle: один успешный start. Повторный start того же handle — ошибка.

Операции:

```lua
container:start({...})
container:stop()
container:kill()
container:wait(timeout)
container:inspect()
container:remove()
```

Принятые правила:

- обычный `stop()` — SIGTERM, затем SIGKILL через 500 мс;
- `kill()` — немедленный SIGKILL;
- отмена всего run — немедленно убивает Lua Runner и все дочерние ресурсы;
- `wait()` возвращает exit code, signal, reason и resource metrics;
- OOM должен быть отличим от non-zero exit.

Пример результата:

```lua
{
    exit_code = nil,
    signal = 9,
    oom_killed = true,
    reason = "oom",
    cpu_time_raw = 1.234,
    cpu_time = 1.180,
    memory_peak = 268435456
}
```

Причины завершения как минимум: `exited`, `stopped`, `killed`, `oom`, `wall_timeout`, `peer_closed`, `output_limit`, `cancelled`, `engine_error`.

---

# 8. Сети и изоляция

## 8.1. Runtime network

- Контейнер без сетевых требований должен запускаться с явным `network=none`, а не зависеть от default rootless networking behavior.
- Сервисы, которым нужно общаться друг с другом, подключаются к internal network конкретного run.
- Runtime internet запрещён.
- Разрешён только обмен с task services, явно подключёнными к сети данного run.
- Никаких `host`, `slirp/pasta` с внешним доступом по умолчанию, произвольных route и внешних network handles.
- DNS aliases/hostnames ограничены сетью run.

В rootless Podman default network behavior может включать `pasta`; поэтому отсутствие явно указанной сети не следует трактовать как гарантированное отсутствие connectivity. Указывать `none` нужно явно. См. [Podman create/network reference](https://docs.podman.io/en/stable/markdown/podman-create.1.html).

## 8.2. Build-time network

Сеть для `RUN` во время build — отдельный режим с разрешённым egress для скачивания зависимостей. Он не должен совпадать с runtime network и не должен видеть другие task services или host-local control endpoints.

Рекомендуемый deployment вариант — egress proxy/firewall policy, которая разрешает нужные внешние адреса/порты, блокирует private host ranges и локальные control planes, и имеет лимиты. Политика может быть более строгой для доверенных/внутренних base images.

**Открыто:** нужен ли произвольный egress в интернет или только разрешённый перечень/прокси. Исходное требование «сборка задаётся автором, сеть разрешена» принято, но конкретный набор адресов должен быть определён deployment policy.

## 8.3. Rootless не отменяет другие защиты

Rootless Podman — один из уровней защиты. Все равно обязательны cgroups, seccomp, минимальные capabilities, namespace isolation, mount restrictions, no-new-privileges, egress policy, PID/disk/output limits и своевременное обновление Podman/kernel.

---

# 9. stdio, realtime и pipe

## 9.1. Режимы

Каждый поток stdin/stdout/stderr настраивается отдельно. Значение по умолчанию — `none`.

| Режим | stdin | stdout/stderr |
|---|---|---|
| `none` | поток закрывается; процесс получает EOF | не читается/не сохраняется, если не включён отдельный диагностический capture |
| `once` | передать указанные бинарные данные при старте, затем EOF | собирать поток в историю, читать после завершения |
| `realtime` | `stdin_write(bytes)` во время работы; возможен `stdin_close()` | `stdout_read`/`stderr_read` ожидают chunk/EOF/timeout; история сохраняется |
| `pipe` | принимает байты из stdout другого container handle | выдаёт байты в stdin другого контейнера |

Lua strings бинарно-безопасны. API не должен считать, что потоки — UTF-8 или текст.

## 9.2. Realtime и coroutine API

Операции, которые ждут IO или завершение контейнера, приостанавливают только текущую Lua coroutine; другие coroutines в том же Lua Runner могут продолжать работу.

Эскиз:

```lua
local pump = spawn(function()
    while true do
        local chunk, err = a:stdout_read()
        if err == "eof" then break end
        assert(chunk, err)
        b:stdin_write(chunk)
    end
end)

local result = a:wait()
pump:join()
```

Для C-функций Lua API, которые yield, использовать корректный continuation protocol (`lua_yieldk` и связанные продолжения), не делать обычный yield через не-yieldable C stack. Lua 5.5 manual объясняет ограничения yield через C calls и механизм continuations. См. [Lua 5.5 manual — Handling Yields in C](https://www.lua.org/manual/5.5/manual.html#4.5).

## 9.3. Pipe graph

- Pipe разрешён только между stdout одного контейнера и stdin другого.
- Все endpoints регистрируются до старта через `start_group`.
- `start_group` — координированный best-effort старт; не обещать атомарность Podman нескольких start calls.
- Циклы разрешены.
- Буферы ограничены; необходим backpressure. Нельзя читать stdout в неограниченную очередь RAM, если consumer не успевает.
- EOF, half-close, broken pipe, consumer exit и cancellation имеют разные результаты.
- Завершение одного контейнера **не должно безусловно транзитивно останавливать все связанные контейнеры**. Политика peer lifecycle задаётся явно на PipeGroup: close edge, stop peer, stop group и т. п.
- Остановка одного конца должна корректно закрыть/разбудить другой endpoint.

## 9.4. История потоков

Исходно пользователь утвердил лимит 512 MiB суммарно на контейнер для stdin/stdout/stderr. Сохранить это как исходный configurable default, если Backend не передаёт более строгий limits profile.

Хранение — disk-backed spool, не 512 MiB RAM buffer:

- ограниченная RAM очередь для realtime;
- временные файлы в workspace/spool для полной истории;
- configurable max per stream, per container и per run;
- `none` не собирает историю;
- `once`, `realtime`, `pipe` сохраняют соответствующие байты;
- после завершения `history()` возвращает artifact handle/metadata или небольшое содержимое, но не должен загружать сотни MiB в Lua memory по умолчанию;
- при hard output cap контейнер убивается с `reason=output_limit`, prefix history сохраняется и может быть загружен в S3;
- политика truncation может существовать для отдельных логов, но не должна скрывать, что output limit был превышен.

Invoker должен различать stderr/stdout и историю stdin (какие байты реально были переданы), не смешивая потоки.

---

# 10. Таймеры, CPU, RAM и resource accounting

## 10.1. Wall time

Wall time измеряется monotonic clock на стороне Invoker. Для каждого run есть глобальный timeout (исходный default — 300 секунд), а также более строгие лимиты из Backend execution profile.

Wall timeout должен применяться watchdog-ом Invoker, а не только Lua циклом `sleep`/poll. Runner не должен иметь возможности обойти timeout, зависнув в бесконечном цикле.

## 10.2. CPU time

Raw CPU time читается из cgroup v2 `cpu.stat`, поле `usage_usec` (user + system, суммарно по ядрам). Значения кэшируются до удаления cgroup/container и доступны после завершения.

Lua API:

```lua
container:cpu_time_raw()
container:cpu_time()
invoker:perf_factor()
```

`cpu_time_raw()` — сырое CPU time. `cpu_time()` — нормализованная оценка через calibration factor. CPU time может превышать wall time, если контейнер использовал несколько ядер.

## 10.3. Калибровка

Принято использовать встроенный в поставку reference benchmark:

1. Один и тот же benchmark/image/version для fleet.
2. Запуск на одном ядре несколько раз; брать медиану.
3. Хранить `benchmark_id`, `benchmark_version`, `calibrated_at`, сырое время и коэффициент `k`.
4. `normalized_cpu = k * raw_cpu` с единой convention для fleet.
5. Записывать calibration metadata в Run metrics/events.
6. Не менять calibration factor посреди активного контеста без явной процедуры.

Допустимая погрешность — обычная для соревнований; **не обещать 10% для всех программ**. Один benchmark не полностью нормализует memory-bound, cache-sensitive, SIMD/FP/integer workloads, turbo и разные микроархитектуры. Raw value сохраняется всегда. Для соревнований можно pin-ить contest на совместимый hardware class.

## 10.4. RAM и OOM

- Лимит задаётся cgroup `memory.max`.
- По умолчанию swap отключается (`memory.swap.max=0`), если это поддерживает host configuration.
- OOM detection использует cgroup `memory.events` и/или Podman inspect OOM state.
- Результат `wait()` содержит `oom_killed=true`, `reason=oom`.
- OOM не должен ошибочно превращаться в обычный non-zero exit.

## 10.5. Общие resource budgets

Ограничения применяются как на контейнер, так и на весь run:

**Per-container:** CPU, RAM, swap, PIDs, wall time, output, writable disk, open files (если возможно), network policy.

**Per-run:** total active containers, images, networks, aggregate RAM/CPU, disk/workspace, total artifact bytes, build time, wall time, Lua Runner CPU/RAM/instruction budget, number of coroutines, RPC inflight count.

Backend может передать limits profile. Invoker имеет абсолютные local hard caps и никогда не позволяет задаче/автору превысить их.

Точные числа большинства лимитов — конфигурация/контестные параметры и требуют отдельного согласования. Исходный глобальный timeout 300 с и 512 MiB stdio history per container — утверждённые исходные defaults, но они остаются настраиваемыми.

## 10.6. Таймеры Lua

`timer.new()`, `timer:start()`, `timer:elapsed()` и `sleep()` доступны для авторских сценариев. Они являются удобными примитивами логики задачи, но не заменяют enforceable wall timeout Invoker.

---

# 11. Lua Runner process

## 11.1. Процессная модель

- На каждый `scripted_lua` judging attempt запускается отдельный Lua Runner OS process.
- Сам Invoker остаётся единственным владельцем Podman API, ресурсов и Backend credentials.
- Lua Runner получает run-specific workspace и локальный RPC endpoint.
- Все операции создания/управления образами, сетями и контейнерами идут через `LuaRpcServer` в основном Invoker.
- Ошибка/краш Lua Runner не должна останавливать другие runs.

## 11.2. Sandbox

Отдельный процесс сам по себе не полноценная sandbox. Требуются OS-level ограничения:

- отдельный unprivileged UID/GID или эквивалентная изоляция;
- отдельный mount namespace/ограниченная root filesystem;
- видна только run workspace и необходимые readonly runtime files;
- нет доступа к Podman socket, root filesystem хоста, credentials, NATS config, backend secret;
- network namespace без внешней сети;
- seccomp/Landlock/namespaces либо совместимый hardening набор;
- cgroup limits для CPU/RAM/PIDs;
- ограничение file descriptors и размер логов;
- запрет spawn arbitrary host subprocesses;
- process group/cgroup для принудительного завершения всех потомков;
- защита RPC socket через Unix peer credentials, случайный socket path/nonce и run-scoped token.

Lua APIs, требующие системных операций, доступны только через RPC, за исключением ограниченного доступа к собственной workspace файловой системе.

## 11.3. Lua standard libraries

Исходный план предлагал оставить `base`, `string`, `table`, `math`, `utf8`, `coroutine`; перенаправить `print` в runner log; удалить `os`, `io`, `debug`, `dofile`, `loadfile` и произвольный `package`.

Обновлённое требование:

- разрешить `require` только для встроенных/поставляемых/подписанных allowlisted Lua modules (`judge.*` и модули задачи, если они входят в проверенную workspace);
- запретить `package.loadlib`, произвольные C modules и произвольную загрузку байткода;
- запретить опасные `os`, `io`, `debug`, `dofile`, `loadfile` interfaces;
- файловый доступ к workspace реализовать через ограниченный fs API или filesystem sandbox;
- Lua `print` отправлять в run-scoped log, с ограничением размера.

## 11.4. Instruction limit и memory limit

- Использовать Lua instruction-count hook (`lua_sethook` с `LUA_MASKCOUNT`) для ограничения расхода инструкций.
- Lua allocator должен учитывать память Lua state, либо применить process cgroup memory limit как дополнительную границу.
- Отдельный watchdog должен завершать Lua process при wall timeout даже если сценарий не yield-ится.
- Hook не должен выполнять блокирующие операции или пытаться вызвать недопустимый yield из hook.

## 11.5. Coroutine scheduler

Модель исполнения — корутины. Внешне API напоминает последовательный код, но блокирующие операции yield-ят текущую coroutine; scheduler возобновляет её при готовности IO/контейнера/RPC.

`spawn(fn)` — запускает coroutine. `handle:join()` — ждёт её завершения. Нужны корректные ошибки, отмена дочерних coroutines и пределы их количества.

Важно: Lua coroutines кооперативные. Бесконечный CPU loop без yield остановит event loop, поэтому instruction hook и внешнее watchdog supervision обязательны.

## 11.6. Local RPC

Предлагаемый protocol: versioned request/response с `request_id`, `run_id`, method, payload, deadline и error envelope. RPC methods делятся на группы:

- `fs.*` — безопасные операции с файлами workspace;
- `image.build`, `image.inspect`;
- `network.create`, `network.remove`;
- `container.create`, `container.start`, `container.start_group`, `container.stop`, `container.kill`, `container.wait`, `container.inspect`;
- `io.stdin_write`, `io.stdin_close`, `io.stdout_read`, `io.stderr_read`, `io.history`;
- `timer.*`, `metrics.*`;
- `report.*`;
- `artifact.create`, `artifact.upload`, `artifact.finalize`.

Все handles проверяются по run owner. RPC rate, concurrency, payload size и deadline ограничены.

---

# 12. Standard Executor — Polygon

## 12.1. Назначение

`StandardExecutor` — единственный встроенный executor для стандартных алгоритмических задач, импортированных Backend ProblemManager из Polygon.

Invoker не импортирует Polygon package из пользовательского ZIP. Он получает нормализованный immutable bundle, подготовленный Backend. В bundle входят `manifest`, тесты, язык, build/run configuration, checker/interactor и другие поддерживаемые execution files.

## 12.2. Языки

- Стандартные Polygon language definitions доступны по умолчанию.
- Автор может добавить custom language.
- Язык может ссылаться на готовый template или включать собственный Containerfile/Dockerfile.
- Автор задаёт build/run commands в рамках ограниченного language configuration.
- Сборка идёт через ImageManager/ContainerManager и подчиняется тем же sandbox/resource limits.

## 12.3. Последовательность Standard judging

Конкретный алгоритм Standard Executor должен соответствовать нормализованной Polygon semantics, включая поддерживаемые test groups/scoring/checkers/validators/interactors.

Общая последовательность:

1. Проверить manifest и execution format version.
2. Подготовить языковое окружение и build context.
3. Собрать solution image согласно Standard semantics.
4. Подготовить тест/группу тестов.
5. Запустить решение в изолированном контейнере с CPU/RAM/wall/output limits.
6. При необходимости запустить interactor/checker в выделенной среде.
7. Получить verdict и test score.
8. Применить test group/scoring rules согласно импортированным настройкам.
9. Отправить `TEST_STARTED`, `TEST_FINISHED`, logs/artifacts и итоговый `PROBLEM_SCORE`.
10. Сохранить артефакты и очистить run.

Начальная Standard policy может выполнять тесты последовательно. Параллельность тестов — отдельная оптимизация и не включается автоматически.

## 12.4. Checker

- Алгоритмический checker может быть C++ с `testlib.h`, как принято в текущей концепции.
- Checker запускается как отдельный изолированный execution unit.
- stdin/stdout/stderr и checker messages сохраняются как artifacts по политике.
- `checker_metadata`/grader data передаётся Backend отдельно от verdict/score/logs.

## 12.5. Polygon feature coverage

Импорт Polygon обязателен в Backend. Поддерживаемые возможности должны быть перечислены в versioned feature matrix. Invoker не должен молча игнорировать неизвестную обязательную настройку. При неизвестном/неподдерживаемом feature bundle validation fails с понятной диагностикой.

Точная матрица Polygon features — отдельное ТЗ; не выводить её из одного только наличия ZIP.

---

# 13. Scripted Lua Executor

## 13.1. Основной принцип

`ScriptedLuaExecutor` создаёт Lua Runner process, предоставляет ему run workspace и ограниченный RPC API и ждёт завершения.

В архиве ревизии есть `runner.lua` и дополнительные файлы задачи. Файлы solution archive извлекаются в поддиректорию `solution/`.

## 13.2. Свобода сценария

Lua может:

- выполнять одну или несколько сборок;
- пересобирать solution для отдельных тестов;
- создавать несколько image/network/container ресурсов;
- запускать solution и auxiliary services;
- запускать несколько контейнеров близко по времени через `start_group`;
- использовать realtime stdio и pipe, в том числе циклические связи;
- выбрать последовательные или параллельные тесты в рамках бюджета;
- перезапускать services и очищать состояние между тестами;
- запускать собственные checker/relay/SQL/HTTP процессы;
- выполнять любой разрешённый workflow.

**Не навязывать** количество сборок, количество запусков решения и порядок тестов. Для `standard` действует отдельная Polygon-compatible semantics.

## 13.3. Отчёты Lua

Логический API:

```lua
report.test_started(test_id)
report.test_verdict(test_id, verdict, { score = 1.25, checker_metadata = "..." })
report.subgroup_score(subgroup_id, score, { checker_metadata = "..." })
report.problem_score(score, { checker_metadata = "..." })
report.build_log(...)          -- лучше создавать Artifact и отправлять ссылку
report.test_stdio(test_id, stdin_artifact, stdout_artifact, stderr_artifact)
```

Окончательные имена/сигнатуры фиксируются в Lua API v1. `report.test_stdio` не должен передавать мегабайты строк в одном RPC: потоки сохраняются как artifacts, report event передаёт ссылки и metadata.

`problem_score` — базовый балл конкретной Submission. Grader рассчитывает отдельный participant-level score и не должен изменять `problem_score`.

Для успешного завершения attempt Backend должен получить валидный final score по contract. Если score не отправлен, Backend не должен молча выводить его из test scores: это определяется явной scoring policy ревизии; по умолчанию успешный `scripted_lua` run обязан отправить `problem_score`.

## 13.4. Checker metadata

`checker_metadata` — отдельное ограниченное строковое поле/byte payload, которое checker/runner может заполнить для Grader. Оно не является логом. Нужно определить:

- encoding (предпочтительно UTF-8 JSON text либо opaque bytes с version field);
- max bytes per test и per attempt;
- version/schema identifier;
- поведение при отсутствии metadata.

Сохранять metadata отдельно от verdict, score, stdout/stderr и обычного log.

## 13.5. Built-in Lua libraries

Поставляемые trusted modules (не новые execution formats):

- `judge.container`;
- `judge.network`;
- `judge.io`;
- `judge.timer`;
- `judge.files`;
- `judge.artifact`;
- `judge.report`;
- `judge.http`;
- `judge.sql`;
- `judge.run_twice`;
- `judge.checker`.

HTTP/SQL/run-twice libraries должны быть реализованы поверх общего Execution Engine. Они не получают собственный путь к Podman.

---

# 14. Build/run artifacts и event delivery

## 14.1. Artifact spool

Invoker не должен держать большие build logs/stdout/stderr целиком в RAM. `ArtifactSpooler`:

1. создаёт временный файл/поток в workspace;
2. пишет данные потоково с per-artifact/per-run hard limits;
3. считает SHA-256 и size;
4. запрашивает у Backend scoped upload target;
5. загружает в S3/MinIO direct presigned URL/multipart;
6. проверяет успешный upload (HEAD/digest metadata или финальный callback);
7. отправляет `ARTIFACT_CREATED` с artifact_id, size, digest, media type, kind, test_id;
8. удаляет локальный spool только после подтверждения сохранения и политики retention.

Временный spool directory ограничен filesystem quota. S3 unavailable не должен бесконечно блокировать весь Invoker; retry/backoff и local disk budget должны быть определены.

## 14.2. Event outbox

Любое событие получает stable `event_id` и sequence. Перед отправкой оно записывается в локальный durable event spool вместе с run fencing token. Затем `Report` вызывается с bounded retry/backoff.

- `Acknowledgement.duplicate=true` означает событие ранее принято Backend и может быть удалено из spool.
- `duplicate=false` означает событие принято сейчас.
- На gRPC transport error, UNAVAILABLE или deadline event остаётся в spool.
- На явную permanent validation error Invoker сохраняет событие для диагностики и переводит run в protocol/infrastructure failure согласно политике.
- Terminal event должен быть последним событием run и отправляться только после всех обязательных результатов/артефактов.

Хранение event spool ограничено диском и переживает перезапуск процесса. Не ACK-нутые события не теряются при кратковременном Backend outage.

## 14.3. Основные события

Минимальные события:

```text
RUN_STARTED
BUILD_STARTED
BUILD_FINISHED
TEST_STARTED
TEST_FINISHED
SUBGROUP_SCORE
PROBLEM_SCORE
ARTIFACT_CREATED
RUNNER_ERROR
RUN_TIMEOUT
RUN_CANCELLED
RUN_FINISHED
```

`BUILD_LOG_CHUNK` без content/reference не использовать: сам chunk upload идёт в Artifact Storage. Если нужен live progress, добавить отдельное событие с progress metadata, а не передавать большой лог в protobuf.

`RUN_FINISHED` содержит outcome: success, execution_error, infrastructure_error, timeout или cancelled. Вердикт решения и статус инфраструктурного run — разные поля/понятия.

---

# 15. Cancellation, timeouts и failure recovery

## 15.1. Отмена Backend

Backend отправляет `CancelRun` для конкретных `attempt_id`, `run_id` и fencing token.

Invoker:

1. Проверяет, что команда относится к текущему run.
2. Атомарно переводит run state в Cancelling.
3. Прекращает Lua Runner немедленно (без 500 ms grace period для самого runner).
4. Прерывает текущую Podman build и все операции/контейнеры run.
5. Останавливает контейнеры принудительно для global cancellation.
6. Закрывает pipe/IO и будит ожидающие coroutines.
7. Сохраняет доступные диагностику/artifacts.
8. Выполняет cleanup.
9. Отправляет `RUN_CANCELLED` и `RUN_FINISHED` (согласовать, нужен ли один terminal event; рекомендуем один canonical RunFinished с outcome cancelled плюс CancelAcknowledged на control channel).
10. Повторная cancel команда безопасна и идемпотентна.

## 15.2. Global timeout

Исходный default — 300 секунд на run, если более строгий limits profile не пришёл от Backend.

Watchdog Invoker отслеживает deadline независимо от Lua scheduler. По истечении:

- закрывает возможность новых API действий;
- kills Lua Runner;
- прекращает build/container/pipe operations;
- делает cleanup;
- отправляет `RUN_TIMEOUT` и terminal result.

## 15.3. Обрыв Backend connectivity

Не отменять run автоматически при одном временном разрыве gRPC. Использовать lease:

- до expiry run может продолжаться, события spool-ятся;
- если lease нельзя продлить в пределах safety margin, Invoker прекращает run;
- reconnect отправляет сохранённые events с прежними IDs/sequence;
- если Backend уже fencing-нул run, старый Invoker прекращает execution и не может опубликовать результаты.

## 15.4. Ошибки

Различать:

- `runner_error` — Lua script error/traceback;
- `runner_instruction_limit`;
- `runner_memory_limit`;
- `runner_process_crash`;
- `build_error`;
- `compile_error` (Standard-specific);
- `timeout`;
- `oom` / `memory_limit`;
- `output_limit`;
- `podman_error`;
- `artifact_storage_error`;
- `backend_protocol_error`;
- `cancelled`;
- `internal_error`.

Инфраструктурные ошибки не должны ошибочно превращаться в пользовательский WA. Backend решает, как классифицировать attempt status и нужна ли повторная попытка.

---

# 16. Ownership, cleanup и Janitor

## 16.1. Нормальный cleanup

В любом исходе run удаляются:

- все принадлежащие ему контейнеры;
- pipe endpoints и stream tasks;
- сети;
- build containers и временные build context;
- временные images, если не retained в безопасном cache;
- Lua Runner process и IPC socket;
- рабочая директория и временный spool после успешного artifact upload.

Удалять сначала контейнеры, затем сети, затем временные images. Каждый cleanup action идемпотентен и журналируется.

## 16.2. Кеш образов

Не удалять image, если он используется другим run или является общим immutable cache object. Учитывать image digest и ссылки/референсы. Run-specific tag не заменяет digest identity.

## 16.3. Crash recovery

Stable `invoker_id` и process-specific `process_epoch` используются для маркировки ресурсов. При старте:

- получить exclusive lock для данного instance state;
- определить предыдущий epoch и проверить, что старый process действительно отсутствует;
- перечислить Podman resources с managed labels;
- сверить ownership journal и реальное состояние;
- удалить orphan resources только своего invoker/run;
- очистить workspace только завершённых/осиротевших runs;
- не затрагивать active resources другого process/instance.

Janitor запускается не только при старте, но и периодически. Labels используются для обнаружения, а не авторизации.

Если несколько Invoker processes работают с одним rootless Podman socket от одного Linux user, они имеют общую административную область Podman. Labels не изолируют их друг от друга. Рекомендуется отдельный rootless Podman user/socket per trust boundary. Shared socket допустим только для процессов одного доверенного admin-domain.

---

# 17. Observability

## 17.1. Логи

Структурированные JSON logs. Каждый run log содержит:

- `invoker_id`, `process_epoch`;
- `run_id`, `judging_attempt_id`, `submission_id`, `task_revision_id`;
- subsystem/component;
- operation/request ID;
- duration;
- error class/code;
- container/network/image IDs только как внутренние диагностические references.

Не логировать signed URLs, access tokens, secret env vars, полный solution source и чувствительные данные.

## 17.2. Metrics

Минимальные метрики:

- active runs / free slots;
- NATS pull/claim latency, redelivery count;
- heartbeat success/error;
- lease renewal failures;
- run duration;
- image build duration/failure;
- container create/start/stop latency;
- Podman API latency/error count;
- Lua process count/crash/limit hits;
- CPU raw/normalized, memory peak, OOM count;
- stdout/stderr bytes and output-limit count;
- artifact upload bytes/latency/failures;
- event spool backlog/retry age;
- cleanup failures/orphan count;
- calibration benchmark result/factor.

Можно использовать OpenTelemetry для traces/metrics/logs с общими correlation IDs. См. [OpenTelemetry semantic conventions](https://opentelemetry.io/docs/specs/semconv/).

## 17.3. Health

Локальный health endpoint или systemd watchdog должен различать:

- liveness — процесс жив;
- readiness — NATS, Backend gRPC, Podman API и workspace/storage health достаточны для получения новых jobs;
- degraded — существующие runs могут завершаться, но новые не принимаются;
- draining — прекращён pull новых jobs, текущие runs завершаются или отменяются по policy.

Не принимать новые jobs, если Podman socket недоступен, work disk заполнен, event spool достиг критического лимита или отсутствует рабочая calibration profile (если она обязательна для этого contest).

---

# 18. Конфигурация

Рекомендуемая структура (формат TOML/YAML/JSON выбрать отдельно):

```toml
[identity]
invoker_id = "..."
state_dir = "/var/lib/podtest-invoker/state"

[backend]
grpc_target = "backend.internal:7443"
# credentials через file/secret provider; не хранить в репозитории

[nats]
servers = ["nats://nats.internal:4222"]
stream = "PODTEST_JOBS"
consumer = "podtest-invokers"
subject = "podtest.judging.jobs.v1"

[podman]
socket_path = "/run/user/1000/podman/podman.sock"
api_family = "libpod"
expected_version = "..."

[workspace]
root = "/var/lib/podtest-invoker/runs"
max_total_bytes = 0 # обязательное значение должно быть задано

[execution]
max_active_runs = 1
run_timeout_seconds = 300
container_stop_grace_ms = 500

[limits]
max_containers_per_run = 8
max_images_per_run = 8
max_networks_per_run = 8
stdio_total_bytes_per_container = 536870912
# Все остальные hard caps задаются явно в production config.

[artifacts]
spool_root = "/var/lib/podtest-invoker/spool"
max_spool_bytes = 0

[calibration]
benchmark_id = "podtest-reference-v1"
runs = 5
```

Это пример, не окончательная схема. Все обязательные safety limits должны иметь ненулевые defaults и проверяться при старте. Если значение небезопасно/не задано, Invoker должен fail startup или применить документированный безопасный default.

---

# 19. Структура исходников Zig

Предлагаемая структура:

```text
podtest-invoker/
├── build.zig
├── build.zig.zon
├── config/
│   └── example.toml
├── proto/
│   └── control.proto
├── src/
│   ├── main.zig
│   ├── app/
│   │   ├── invoker_core.zig
│   │   ├── run_supervisor.zig
│   │   ├── state_machine.zig
│   │   └── shutdown.zig
│   ├── control/
│   │   ├── grpc_client.zig
│   │   ├── nats_consumer.zig
│   │   ├── lease_manager.zig
│   │   ├── command_watcher.zig
│   │   ├── event_outbox.zig
│   │   └── artifact_grants.zig
│   ├── podman/
│   │   ├── client.zig
│   │   ├── api_types.zig
│   │   └── errors.zig
│   ├── execution/
│   │   ├── engine.zig
│   │   ├── image_manager.zig
│   │   ├── container_manager.zig
│   │   ├── network_manager.zig
│   │   ├── volume_manager.zig
│   │   ├── io_manager.zig
│   │   ├── pipe_manager.zig
│   │   ├── resource_manager.zig
│   │   ├── metrics_manager.zig
│   │   └── ownership.zig
│   ├── executor/
│   │   ├── executor.zig
│   │   ├── standard/
│   │   └── scripted_lua/
│   ├── lua/
│   │   ├── process_manager.zig
│   │   ├── rpc_server.zig
│   │   ├── protocol.zig
│   │   └── sandbox.zig
│   ├── workspace/
│   │   ├── manager.zig
│   │   ├── archive.zig
│   │   └── secure_path.zig
│   ├── artifacts/
│   │   ├── spooler.zig
│   │   ├── s3_client.zig
│   │   └── metadata.zig
│   ├── cleanup/
│   │   ├── manager.zig
│   │   └── janitor.zig
│   ├── calibration/
│   ├── observability/
│   └── tests/
├── docs/
│   ├── architecture.md
│   ├── control-api.md
│   ├── lua-api.md
│   ├── bundle-format.md
│   └── deployment.md
└── examples/
    ├── standard/
    └── scripted-lua/
```

Можно скорректировать структуру по результатам реализации, но слои и зависимости должны оставаться раздельными.

---

# 20. Старый Invoker

Старый код пользователя находится в его локальной среде по адресу `~/programming/podtestInvokerOld`.

**Требование:** новый Invoker пишется с нуля в отдельном проекте. Старый проект не изменять, не форматировать, не переименовывать файлы, не обновлять зависимости и не удалять.

Если старый каталог доступен агенту разработки, разрешено изучить его исключительно read-only, чтобы понять существующие эксперименты/API/библиотеки. Не переносить архитектуру автоматически и не копировать код без проверки. Основной source of truth — текущая спецификация и актуальный `control.proto`; расхождения со старым кодом фиксировать, а не подгонять новую реализацию под старую.

---

# 21. Тестирование и критерии приёмки

## 21.1. Contract tests

- Go Backend generated gRPC stubs совместимы с Zig client.
- `Heartbeat`, `Claim`, `Report`, `RenewLease`, `WatchCommands` и artifact upload grants работают через реальный gRPC server.
- TLS/mTLS/service credentials проверяются.
- Protobuf unknown fields/forward compatibility не ломают клиента.
- Duplicate event получает ACK с `duplicate=true`.
- Старый fencing token/event отклоняется Backend.

## 21.2. NATS tests

- несколько Invoker-ов получают разные сообщения из общего pull consumer;
- при отсутствии свободных slots Invoker не забирает лишние jobs;
- Claim transport failure приводит к NAK/retry;
- job, уже claimed/terminal, ACK-ится как stale;
- redelivery не создаёт параллельный второй run для того же fencing generation;
- crash Invoker после Claim и до старта приводит к lease expiry/recovery Backend.

## 21.3. Archive/workspace tests

- path traversal и absolute paths отклоняются;
- symlink/hardlink escape отклоняется;
- zip/tar bombs ограничиваются размером/числом файлов;
- архив не может записать поверх системных файлов;
- workspace двух runs не пересекаются;
- cleanup удаляет только ресурсы своего run.

## 21.4. Podman tests

- create/build/start/inspect/stop/kill/wait/remove через Unix socket;
- build logs потоково сохраняются;
- build cancellation удаляет build leftovers;
- runtime container без сети реально не имеет внешнего connectivity;
- task internal network не пересекается с другим run;
- memory limit вызывает распознаваемый OOM;
- CPU/PID/time limits реально применяются;
- socket access отсутствует у Lua Runner и tested containers.

## 21.5. Lua tests

- отдельный процесс на каждый run;
- RPC handles нельзя использовать между runs;
- coroutine `stdout_read` не блокирует другие coroutines;
- infinite loop обрывается instruction limit;
- memory exhaustion останавливает только конкретный Lua Runner;
- process crash не влияет на остальные runs;
- `require` доступен только для allowlisted modules;
- отмена run завершает Lua process и дочерние resources.

## 21.6. IO/pipe tests

- stdin `none` получает EOF;
- stdin `once` передаёт точные bytes и EOF;
- stdout/stderr `none` не сохраняются;
- `once` history доступна после exit;
- realtime read различает chunk/EOF/timeout/error;
- backpressure не приводит к бесконтрольному росту RAM;
- pipe cycle двух процессов работает в обе стороны;
- закрытие одного endpoint приводит к определённому EOF/peer behavior;
- hard output cap даёт `output_limit` и сохраняет накопленный prefix.

## 21.7. Recovery/cleanup tests

- `kill -9` Invoker оставляет labels/workspace, новый процесс после liveness check удаляет только orphan resources;
- janitor не удаляет активный run другого `process_epoch`;
- временная потеря gRPC приводит к локальному spool и последующей доставке;
- artifact upload retry не создаёт разные artifact IDs для одного logical artifact;
- cleanup идемпотентен и безопасен после частичного сбоя.

## 21.8. Run acceptance

Один end-to-end test должен пройти полностью:

1. Backend публикует job в JetStream.
2. Invoker получает job и Claim-ит run.
3. Invoker скачивает source+bundle и проверяет digest.
4. Standard Executor или Lua Runner выполняет тестирование.
5. Container resource limits применяются.
6. Test verdicts, base score и artifacts отправляются Backend.
7. Backend ACK-ит events.
8. Invoker очищает ресурсы и workspace.
9. Judging attempt в Backend получает корректный terminal state.

---

# 22. План реализации

Реализовывать вертикальными срезами, не начинать сразу все подсистемы.

1. **Contract spike:** собрать Zig gRPC client и Protobuf generation для точной версии Zig; прогнать against Go test server с текущим `control.proto`.
2. **Podman spike:** Unix socket HTTP client; версии API; build/create/start/inspect/stop/remove.
3. **Skeleton:** config, logging, lifecycle, systemd, health, instance ID/epoch.
4. **Control plane:** NATS pull, Heartbeat, Claim, lease, command watcher, Report, event outbox.
5. **Workspace:** download, checksum, secure archive extraction, cleanup.
6. **Podman adapter:** images, networks, containers, ownership handles.
7. **Resource manager:** cgroups v2, CPU/RAM/PIDs/wall/disk/output limits, OOM classification.
8. **IO manager:** stdio once/none/realtime and disk-backed history.
9. **Pipe manager:** bounded streams, backpressure, EOF, start groups and cycles.
10. **Artifact spooler:** S3 presigned upload and metadata events.
11. **Lua Runner process:** supervision, filesystem sandbox, local RPC, instruction/memory limits.
12. **Lua coroutine API:** yieldable IO/container wait and spawn/join.
13. **Scripted Lua end-to-end:** sample task, test output, base score, cancel/recovery.
14. **Standard Executor:** supported Polygon normalized bundle and reference tasks.
15. **Hardening:** janitor, crash recovery, security, load/concurrency tests.
16. **Performance calibration:** benchmark versioning and raw/normalized CPU reporting.
17. **Docs and release:** backend contract, Lua API, bundle format, deployment, operations runbook.

---

# 23. Открытые вопросы перед production

Эти детали нужно решить отдельными ADR/контрактными изменениями; не выдумывать их в коде без фиксации:

1. Final `control.proto`: точная форма WatchCommands/Cancel, RenewLease, upload grant, event oneof, fencing token и ACK semantics.
2. gRPC implementation for Zig 0.17.0: libgrpc C core vs проверенный Zig library vs отдельный transport bridge. Нужен spike до большой реализации.
3. NATS stream, subject, consumer name, retention, AckWait/Backoff/MaxDeliver и credentials policy.
4. Canonical archive format внутреннего Task Bundle и Solution Artifact; tar.zst/tar.gz/другой вариант.
5. Maximum task bundle/source archive sizes, total unpacked bytes/files/depth.
6. Exact resource limits: max containers/images/networks per run, total memory, CPU, PIDs, disk, build timeout, output/spool quota.
7. Build-time egress: unrestricted internet через policy gateway или allowlist/proxy.
8. `max_active_runs` на Invoker и fleet scheduling; допустимая concurrency внутри одного Lua run.
9. Pipe group termination semantics и допустимый fan-out/multiple writers.
10. `checker_metadata` encoding, size and version schema.
11. Полная Polygon feature matrix и что считается unsupported import.
12. Удаление shared/cache images и retention policy.
13. Event spool max size и поведение, если Backend/S3 долго недоступны.
14. Retrying/recovering attempt: повторно использовать логический JudgingAttempt с новым run/fencing или создавать новый attempt; рекомендуем новый run generation под тем же attempt, пока нет принятого terminal result.
15. Порог/срок calibration и правила pin-инга hardware class.

---

# 24. Технические источники

- [Zig 0.17.0 release](https://ziglang.org/news/0.17.0-released/)
- [Zig 0.17.1 release](https://ziglang.org/news/0.17.1-released/)
- [Zig downloads / latest stable](https://ziglang.org/download/)
- [Podman system service / API socket](https://docs.podman.io/en/latest/markdown/podman-system-service.1.html)
- [Podman Libpod API reference](https://docs.podman.io/en/latest/_static/api.html)
- [Podman build options and build network](https://docs.podman.io/en/latest/markdown/podman-build.1.html)
- [Podman create/network](https://docs.podman.io/en/stable/markdown/podman-create.1.html)
- [NATS JetStream consumers](https://docs.nats.io/nats-concepts/jetstream/consumers)
- [nats-io/nats.zig](https://github.com/nats-io/nats.zig)
- [NATS pull consumers](https://docs.nats.io/learn/jetstream/pull-consumers)
- [NATS acknowledgements](https://docs.nats.io/jetstream/concepts/acknowledgements)
- [Lua 5.5 reference manual](https://www.lua.org/manual/5.5/manual.html)
- [OpenTelemetry semantic conventions](https://opentelemetry.io/docs/specs/semconv/)
- [gRPC C core](https://github.com/grpc/grpc)
- [zig-protobuf](https://github.com/Arwalk/zig-protobuf)

