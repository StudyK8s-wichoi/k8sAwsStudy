# Docker Compose → Kubernetes 마이그레이션 작업 정리

## 개요

Docker Compose로 운영 중이던 Spring Boot 마이크로서비스를 Kubernetes(kind)로 마이그레이션.
Eureka 기반 서비스 디스커버리 → K8s 네이티브 DNS로 전환.

---

## 서비스 구성

| 서비스 | 역할 |
|--------|------|
| gateway | Spring Cloud Gateway (API 라우팅) |
| user-manage | 사용자 서비스 |
| chapter | 챕터 서비스 |
| problem | 문제 서비스 |
| flyway | DB 스키마 마이그레이션 (Job) |

---

## 1. 설정 파일 분리 (Spring Profiles)

### 변경 전
- `docker/yml/application-{service}.yml` 파일을 컨테이너에 볼륨 마운트
- `--spring.config.location=./application.yml`로 외부 파일 지정
- `docker/yml/` 폴더에 환경별 yml 파일 관리

### 변경 후
- 모든 설정을 JAR 내부 classpath로 관리
- Spring Profiles로 환경 분리

```
{service}/src/main/resources/
  application.yaml          # 공통 (앱 이름, 포트, profiles.include)
  application-local.yaml    # 로컬 전용: Eureka 등록
  application-k8s.yaml      # K8s 전용: Eureka 비활성화, port 8080

common_core/src/main/resources/
  application-common.yml    # 로깅 설정

common_web/src/main/resources/
  application-web.yml       # DB/Redis 설정 (env var 기반)
```

### 실행 방식

| 환경 | 활성화 방법 | 로드되는 프로필 |
|------|------------|----------------|
| 로컬 Docker Compose | `--spring.profiles.active=local` | base + common + web + local |
| Kubernetes | `SPRING_PROFILES_ACTIVE=k8s` (env) | base + common + web + k8s |

### 서비스별 프로필 차이

| 설정 | local | k8s |
|------|-------|-----|
| server.port | 8081/8082/8083 | 8080 |
| eureka | 등록 (`EUREKA_HOST`, `EUREKA_PORT` env var) | `enabled: false` |
| gateway 라우팅 | `lb://service-name` (Eureka 기반) | `http://{svc}.backend.svc.cluster.local:8080` |

---

## 2. docker/yml 폴더 제거

모든 설정이 JAR 내부로 이동함에 따라 `docker/yml/` 폴더 전체 삭제.

**eureka 서버**는 `common_core` 의존성이 없어 classpath에 `application-common.yml`이 없음  
→ `eureka/src/main/resources/application.yaml`에 로깅 설정 인라인으로 추가 후 외부 yml 마운트 제거.

**flyway**는 `flyway/src/main/resources/application.yaml`이 기존 외부 yml과 동일한 내용이었으므로 그대로 사용.

---

## 3. docker-compose-was.yml 변경

```yaml
# Before
volumes:
  - ./yml/application-user.yml:/usr/src/app/application.yml
  - ./yml/application-common.yml:/usr/src/app/application-common.yml
  - ./yml/application-web.yml:/usr/src/app/application-web.yml
command: java -jar app.jar --spring.config.location=./application.yml

# After
command: java -jar app.jar --spring.profiles.active=local
```

---

## 4. Dockerfile CMD 추가

모든 서비스 Dockerfile에 `CMD` 누락 → eclipse-temurin:21의 기본 명령인 JShell이 실행되는 버그 수정.

```dockerfile
FROM eclipse-temurin:21
WORKDIR /usr/src/app
COPY ./build/libs/*.jar app.jar
CMD ["java", "-jar", "app.jar"]   # 추가
```

대상: `gateway`, `user`, `chapter`, `problem`, `flyway`

---

## 5. common_web application-web.yml

```yaml
# Before
ddl-auto: update

# After
ddl-auto: none   # flyway가 스키마 관리
```

---

## 6. K8s 리소스 구성

### 디렉토리 구조

```
k8s/
  common/
    kind-config.yaml      # kind 클러스터 설정
    namespace.yaml        # backend namespace
    secret.yaml           # DB/Redis/JWT 시크릿
  gateway/
    deployment.yaml
    service.yaml
  user/
    deployment.yaml
    service.yaml
  chapter/                # 신규 생성
    deployment.yaml
    service.yaml
  problem/
    deployment.yaml
    service.yaml
  flyway/
    job.yaml              # 1회성 마이그레이션 Job
  nginx-ingress/
    deploy.yaml           # NGINX Ingress Controller
    ingress.yaml          # 라우팅 규칙
  start.sh                # 클러스터 시작 스크립트
  stop.sh                 # 클러스터 종료 스크립트
```

### Secret 구성 (`k8s/common/secret.yaml`)

```yaml
DB_HOST: "mysql"      # k8s 내부 Service 이름 (external-db.yaml 에서 정의)
DB_PORT: "3306"
DB_NAME: "TEST"
DB_USER: "test"
DB_PASSWORD: "test"
REDIS_HOST: "redis"   # k8s 내부 Service 이름
REDIS_PORT: "6379"
REDIS_PASSWORD: "study1234"
JWT_SECRET: "..."
```

### 호스트 DB 접근 구조 (External DB Service 패턴)

```
K8s Pod
  → CoreDNS (mysql.backend.svc.cluster.local → ClusterIP)
  → kube-proxy
  → EndpointSlice 에 등록된 호스트 IP (kind 게이트웨이, 예: 172.18.0.1)
  → 호스트 Mac 의 Docker Compose MySQL/Redis (포트 3306/6379 공개)
```

**핵심 아이디어**: selector 없는 `Service` + 수동 `EndpointSlice` 로 클러스터 밖 DB 를
k8s 네이티브 DNS 이름으로 감싼다.

- `k8s/common/external-db.yaml` 이 `mysql` / `redis` Service 정의.
- `k8s/common/external-db-endpoints.template.yaml` 이 EndpointSlice 템플릿
  (IP 자리는 `__HOST_IP__` 플레이스홀더).
- `start.sh` 가 kind 도커 네트워크 게이트웨이 IP 를 동적으로 찾아
  `sed` 로 치환 후 kubectl 에 apply. EndpointSlice 는 `kubernetes.io/service-name`
  라벨로 Service 와 연결된다.
- CoreDNS ConfigMap 을 건드리지 않으므로 초기 구성이 단순.
- 나중에 EKS + RDS/ElastiCache 로 옮길 때는 `external-db.yaml` 의
  Service 를 `type: ExternalName` + `externalName: <RDS endpoint>` 로 교체하고
  EndpointSlice 템플릿 파일과 sed 치환 블록만 삭제하면 됨. Secret 의
  `DB_HOST=mysql` 은 그대로 유지.

> 이전 방식(`host.docker.internal` + CoreDNS hosts 블록 패치)은 제거됨.
> ExternalName 이 아니라 Service+EndpointSlice 를 쓰는 이유: ExternalName 은
> CNAME 이라 타깃이 **DNS 이름** 이어야 하고 IP 는 허용되지 않는데,
> 로컬 맥 호스트는 파드에서 해석 가능한 정식 DNS 이름이 없음.

---

## 7. start.sh 동작 순서

```
[1] kind 클러스터 확인/생성 (이미 있으면 스킵)
[2] namespace + secret + external-db(Service) 적용
    → kind 게이트웨이 IP 를 감지해 mysql/redis EndpointSlice 주입
[3] NGINX Ingress Controller 설치 및 대기
[4] Gradle bootJar 빌드
[5] Docker 이미지 빌드 → kind 로드
[6] Flyway Job 실행 및 완료 대기
[7] 서비스 배포 (gateway, user, chapter, problem)
```

### 사용법

```bash
# DB 먼저 실행
cd docker && docker-compose -f docker-compose-db.yml up -d

# K8s 클러스터 시작
./k8s/start.sh

# 종료
./k8s/stop.sh
```

---

## 8. 버그 수정 내역

| 파일 | 문제 | 수정 |
|------|------|------|
| 모든 `Dockerfile` | `CMD` 없어서 JShell 실행됨 | `CMD ["java", "-jar", "app.jar"]` 추가 |
| `k8s/gateway/service.yaml` | YAML에 `~` 문자 포함 → 파싱 오류 | 제거 |
| `k8s/user/service.yaml` | 서비스명 `user_manage` (언더스코어) → K8s DNS 불가 | `user-manage` (하이픈)으로 변경 |
| `k8s/flyway/job.yaml` | 삭제된 `flyway-config` ConfigMap 참조 | ConfigMap 제거, `java -jar app.jar` 직접 실행 |
| `k8s/common/secret.yaml` | `DB_PORT: 5432` (PostgreSQL), `127.0.0.1` | `3306`, `host.docker.internal`으로 수정 |
| `k8s/nginx-ingress/ingress.yaml` | `host: api.local` 필수 → IP 직접 접근 불가 | `host` 필드 제거 |

---

## 9. 접속 확인

- Swagger UI: `http://127.0.0.1/swagger-ui.html`
- API: `http://127.0.0.1/api/v1/{service}/...`

---

## 10. 향후 작업 (로드맵)

1. **Helm Chart** 도입 - 서비스 수 증가 시 manifest 관리 효율화
2. **AWS EKS** 전환 - ECR, Terraform, ALB 연동
3. **CI/CD** - GitHub Actions + ArgoCD
4. **모니터링** - Prometheus + Grafana
