# CLAUDE.md — AI Prospector CRM

## Descripción del proyecto

CRM web en Ruby on Rails para prospectar negocios locales que necesiten servicios de diseño web, SEO o posicionamiento. Los agentes de IA buscan empresas automáticamente, las auditan y el usuario les da seguimiento manual en un pipeline.

## Stack

- **Backend:** Ruby on Rails 7.2, PostgreSQL, Sidekiq + Redis
- **Frontend:** Hotwire (Turbo Frames + Turbo Streams + Stimulus), Tailwind CSS
- **APIs externas:** Apify (scraping), Google PageSpeed Insights, Anthropic Claude API
- **Deploy:** Render.com (web + worker dyno)

## Documentación clave

- **Spec de diseño:** `docs/superpowers/specs/2026-05-06-ai-prospector-crm-design.md`
- **Plan de implementación:** `.omc/plans/2026-05-06-ai-prospector-crm-plan.md`

## Modelos principales

| Modelo | Propósito |
|---|---|
| `User` | Autenticación single-user con `has_secure_password` |
| `SearchConfig` | Configuración de búsqueda (ciudad, radio, categorías). Singleton via `SearchConfig.current` |
| `PipelineStage` | Etapas del pipeline. **Fuente única de verdad** para el estado de cada Prospect |
| `Prospect` | Negocio encontrado. Referencia `pipeline_stage` por FK, no string status |
| `WebAudit` | Resultado de auditoría PageSpeed + Claude AI. 1:1 con Prospect |
| `Activity` | Log manual de seguimiento (notas, llamadas, emails) |
| `ScanJob` | Historial de ejecuciones del agente de búsqueda |

## Decisiones de arquitectura importantes

### Estado del pipeline
`Prospect` **no tiene** campo `status` string. Usa `pipeline_stage_id` FK a `PipelineStage`. Esto permite etapas configurables sin código adicional.

### Autenticación
Sin Devise. `User` tiene `has_secure_password`. `ApplicationController` tiene `before_action :require_login`. Login en `/login`.

### Deduplicación de prospectos
- **Google Maps:** índice único en `google_maps_place_id` (parcial, `WHERE IS NOT NULL`)
- **Manual:** `pg_trgm` extension con `similarity(LOWER(business_name), LOWER(?)) >= 0.8` dentro del mismo `city`

### WebAudit
Re-auditoría sobreescribe el registro existente. Sin historial en v1. Upsert via `find_or_initialize_by(prospect: prospect)`.

### Jobs y colas Sidekiq
- `search` (2 workers): `ProspectSearchJob` — llama Apify, crea Prospects
- `audit` (5 workers): `WebAuditJob` — llama PageSpeed + Claude API en paralelo con threads
- `default` (1 worker): `ScheduledScanJob` — cron que respeta límite de 1 scan/día

### `WebAuditJob` no usa callbacks
`WebAuditJob` es encolado **explícitamente** por `ProspectSearchJob` tras crear cada Prospect con website. No usa `after_create` callbacks para evitar ejecución involuntaria desde seeds/console.

### Integración marketingskills
Los archivos `app/ai/skills/seo_audit.md`, `page_cro.md`, `site_architecture.md` son copias de `coreyhaines31/marketingskills` (MIT License). Se usan como `system` prompt en `Audit::AiAnalysisService` con `tool_use` para forzar output JSON estructurado.

### Turbo Streams
- `ProspectSearchJob` hace broadcast a `"scan_jobs"` al completar → actualiza dashboard
- `WebAuditJob` hace broadcast a `"prospect_#{id}"` → actualiza card de auditoría en tiempo real

## Servicios externos

| Servicio | Clase | Notas |
|---|---|---|
| Apify Google Maps | `Apify::GoogleMapsService` | Actor: `compass/crawler-google-places`. Polling hasta completar |
| Apify Social Media | `Apify::SocialFinderService` | Actor: `apify/social-media-scraper`. Falla silenciosamente |
| PageSpeed | `Audit::PageSpeedService` | Gratuito sin key. Con key `GOOGLE_PAGESPEED_API_KEY` mayor cuota |
| Claude AI | `Audit::AiAnalysisService` | Modelo `claude-sonnet-4-6`, `max_tokens: 2048`, tool_use para JSON |
| Deduplicación | `Prospect::DeduplicationService` | Requiere extensión `pg_trgm` en PostgreSQL |

## Límites de costo

- Máx 100 prospectos por scan (configurable en `SearchConfig.max_prospects_per_scan`)
- Máx 1 auto-scan por día (hardcoded en `ScheduledScanJob::MAX_SCANS_PER_DAY`)
- Intervalo mínimo entre scans: 12 horas (hardcoded)
- Claude API: `max_tokens: 2048` por llamada, retry máx 3 veces

## Convenciones de código

- Todos los wrappers externos en `app/services/` agrupados por dominio (apify/, audit/, prospect/)
- Los controllers son delgados — lógica de negocio en services y models
- Respuestas Turbo Stream en archivos `*.turbo_stream.erb` junto a las vistas normales
- Scopes de filtrado en el modelo `Prospect` via `scope :filter_by, ->(filters) { ... }`

## Variables de entorno

```bash
DATABASE_URL=
REDIS_URL=
APIFY_API_TOKEN=
ANTHROPIC_API_KEY=
ADMIN_EMAIL=
ADMIN_PASSWORD=
GOOGLE_PAGESPEED_API_KEY=   # Opcional
```

## Fases de implementación

Ver `.omc/plans/2026-05-06-ai-prospector-crm-plan.md` para el plan completo con 9 fases.

Orden: Setup Rails → Migraciones → Auth → Servicios externos → Jobs → Controllers → Vistas → Integración → Deploy
