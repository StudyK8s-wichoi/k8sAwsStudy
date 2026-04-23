# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Spring Boot microservices learning project ("학습 플랫폼"). The goal is to migrate from local Docker Compose → local Kubernetes (kind) → AWS EKS with CI/CD and monitoring. The code itself is a multi-module Gradle project; the Docker Compose and k8s/ assets are alternate deployment targets for the *same* JARs.

Java 21, Spring Boot 3.5.3, Spring Cloud 2025.0.0. Gradle with a `buildSrc` convention-plugin setup.

## Common commands

Build / test (from repo root):

```bash
./gradlew build                     # full build with checkstyle + tests
./gradlew :user:bootJar             # build a single service fat jar
./gradlew :user:test                # run tests for one module
./gradlew :user:test --tests '*FooTest.bar'   # single test method
./gradlew checkstyleMain            # Naver checkstyle (configured in my-java-base.gradle)
```

Local Docker Compose (DB + services):

```bash
cd docker && docker-compose -f docker-compose-db.yml up -d     # MySQL + Redis
cd docker && docker-compose -f docker-compose-was.yml up -d    # services (uses profile=local)
```

Local Kubernetes (kind) — full rebuild + deploy in one shot:

```bash
./k8s/start.sh     # creates kind cluster, patches CoreDNS, installs NGINX Ingress,
                   # builds all bootJars + docker images, loads into kind, runs flyway Job,
                   # deploys gateway/user/chapter/problem + ingress
./k8s/stop.sh      # deletes the kind cluster
```

`start.sh` assumes MySQL/Redis are running via `docker-compose-db.yml` on the host — pods reach them through `host.docker.internal`, which is injected into CoreDNS by the script. If you edit a single service, re-running `start.sh` will rebuild and reload (kind is idempotent on existing clusters).

Access after `start.sh`: `http://127.0.0.1/` (or add `127.0.0.1 api.local` to `/etc/hosts`). Swagger at `/swagger-ui.html`.

## Architecture

### Gradle module layout

Convention plugins live in `buildSrc/src/main/groovy/`:

- `my-java-base.gradle` — Java 21 toolchain, Naver checkstyle, Lombok, Spring BOM import.
- `base-library.gradle` — library jar (no bootJar). Used by `common_*`.
- `spring-app.gradle` — `base` + `org.springframework.boot` plugin; produces bootJar.
- `spring-cloud-app.gradle` — `spring-app` + Spring Cloud BOM.
- `querydsl.gradle` — QueryDSL annotation processing.

Runtime services (each is an independent Spring Boot app with its own `Dockerfile`):

- `gateway` — Spring Cloud Gateway (webflux). Routes to downstream services.
- `user` (image tag: `user_manage`), `chapter`, `problem` — domain services, Eureka client in local profile.
- `eureka` — Eureka server (used only in `local` profile).
- `flyway` — one-shot JDBC app that runs Flyway migrations; deployed as a K8s `Job`, not a long-running Deployment.

Libraries consumed via `project(':...')`:

- `common_core` — Jackson, validation, slf4j (no Spring).
- `common_web` — JPA + MySQL, Redis, Spring Web, Springdoc. Adds `application-web.yml` to classpath (DB/Redis config via env vars). `ddl-auto: none` — Flyway owns the schema.
- `common_api` — Spring Cloud OpenFeign client stubs.

### Profiles: local vs k8s

A major design point — understand this before touching any `application*.yaml` file.

All config lives on the classpath inside each jar. Environment is chosen via Spring profile, not by mounting files:

| Env | Activation | Ports | Service discovery | Gateway routes |
|---|---|---|---|---|
| Docker Compose | `--spring.profiles.active=local` | 8081/8082/8083 | Eureka (`EUREKA_HOST`/`EUREKA_PORT` env) | `lb://service-name` |
| Kubernetes | `SPRING_PROFILES_ACTIVE=k8s` | 8080 | Eureka **disabled** | `http://{svc}.backend.svc.cluster.local:8080` |

Files per service: `application.yaml` (common), `application-local.yaml`, `application-k8s.yaml`. `common_web/.../application-web.yml` and `common_core/.../application-common.yml` are pulled in via `spring.profiles.include`. Eureka is absent from `common_web`, so the `eureka` module carries its own inline logging config.

When adding a new service: create both `application-local.yaml` and `application-k8s.yaml`, add a `Dockerfile` with an explicit `CMD ["java","-jar","app.jar"]` (missing `CMD` on `eclipse-temurin:21` silently launches JShell), and register the module in `settings.gradle` plus the start.sh build/image/load/apply lists.

### Kubernetes layout (`k8s/`)

```
common/       kind-config.yaml, namespace (backend), secret.yaml (DB/Redis/JWT)
{svc}/        deployment.yaml + service.yaml per service
flyway/       one-shot Job (not a Deployment)
nginx-ingress/ deploy.yaml + ingress.yaml (no host field — IP access)
```

Gotchas documented in `docs/k8s-migration.md` and worth preserving:

- Service names must use hyphens, not underscores (`user-manage`, not `user_manage`) — DNS-1123.
- `host.docker.internal` resolution inside pods only works because `start.sh` patches the CoreDNS ConfigMap with the host IP — do not remove that step.
- Secret uses MySQL port `3306` and points at `host.docker.internal`; the DB is still the Compose-managed MySQL, not an in-cluster StatefulSet (Phase 1 roadmap item).
- Flyway's K8s manifest is a `Job`, and the image is built from the `flyway` gradle module — don't try to reuse a ConfigMap-based runner; that was removed.

## Code style

- Naver checkstyle rules at `naver-checkstyle-rules.xml` (suppressions in `naver-checkstyle-suppressions.xml`). Enforced on `checkstyleMain` — only `src/main/java`, not tests.
- IntelliJ formatter: `naver-intellij-formatter.xml`.
- UTF-8 source encoding, Lombok enabled everywhere via `my-java-base`.

## References

- `README.md` — 5-phase roadmap (local k8s → Helm → EKS → CI/CD → ops). Phase 1 is in progress; Helm/EKS/ArgoCD are not yet implemented.
- `docs/k8s-migration.md` — authoritative write-up of the Compose→K8s migration (profile split, CoreDNS patch, bug fixes). Read this before touching k8s manifests or profile configs.