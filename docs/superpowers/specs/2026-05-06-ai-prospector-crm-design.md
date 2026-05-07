# AI Prospector CRM — Especificación de Diseño

**Fecha:** 2026-05-06
**Estado:** Aprobado para implementación
**Stack:** Ruby on Rails 7.2 · Hotwire (Turbo + Stimulus) · PostgreSQL · Redis · Sidekiq · Apify · Anthropic API

---

## 1. Resumen del Proyecto

CRM web construido en Rails que usa agentes de IA para descubrir prospectos locales (negocios sin sitio web, con web desactualizada o con SEO deficiente) y generar un expediente completo de cada uno. El usuario hace el seguimiento comercial de forma manual dentro del CRM. Todo queda persistido en base de datos.

**Problema que resuelve:** Encontrar manualmente negocios locales que necesiten servicios web (diseño, SEO, posicionamiento) es lento y disperso. Este CRM automatiza el descubrimiento y la auditoría, dejando al usuario solo la parte de ventas.

**v1: app de un solo usuario.** Sin multi-tenant. El registro de acceso se crea por seed.

---

## 2. Arquitectura General

```
┌─────────────────────────────────────────────────────┐
│                  Rails App (Monolito)                │
│                                                     │
│  ┌──────────────┐    ┌────────────────────────────┐ │
│  │   Web UI     │    │      Background Jobs       │ │
│  │  (Hotwire /  │    │         (Sidekiq)          │ │
│  │   Turbo)     │    │                            │ │
│  │              │◄───│  ProspectSearchJob         │ │
│  │  Dashboard   │    │  WebAuditJob               │ │
│  │  Prospectos  │    │  ScheduledScanJob          │ │
│  │  Pipeline    │    └────────────────────────────┘ │
│  │  Config      │                                   │
│  └──────────────┘                                   │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │          PostgreSQL  +  Redis                │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
         │                          │
         ▼                          ▼
   Apify API               Google PageSpeed
   Google Maps Scraper      Insights API (free)
   Social Media Finder    Anthropic Claude API
                          (marketingskills prompts)
```

### Stack Técnico

| Capa | Tecnología |
|---|---|
| Framework | Ruby on Rails 7.2 |
| Frontend | Hotwire (Turbo Frames + Turbo Streams + Stimulus) |
| Base de datos | PostgreSQL |
| Cola de jobs | Sidekiq + Redis |
| Scraping | Apify: `compass/crawler-google-places` (Google Maps) + `apify/social-media-scraper` (redes sociales) |
| Auditoría técnica | Google PageSpeed Insights API (gratuita, sin key requerida) |
| Auditoría SEO/IA | Anthropic Claude API con SKILL.md de marketingskills como system prompt |
| Drag & drop Kanban | SortableJS con Stimulus wrapper |
| Deploy | Render.com (web service + worker dyno + PostgreSQL + Redis) |

---

## 3. Autenticación

App de un solo usuario. Sin Devise. Implementación con `has_secure_password` en un modelo `User`.

- Login en `GET /login` (formulario email + contraseña)
- Sesión en cookie cifrada de Rails (`session[:user_id]`)
- Todos los controllers heredan de `ApplicationController` con `before_action :require_login`
- Usuario admin creado en `db/seeds.rb` con email y contraseña configurable por ENV
- No hay registro público ni recuperación de contraseña en v1

```ruby
# ENV requerido para seed
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=changeme123
```

---

## 4. Modelos de Datos

### `User`
```ruby
t.string :email,           null: false, index: { unique: true }
t.string :password_digest, null: false
t.timestamps
```

### `SearchConfig`
Una sola instancia en la base de datos. Se accede como `SearchConfig.current` — método de clase que hace `first_or_create` con valores por defecto. Sin `user_id` en v1.

```ruby
t.string   :city,                      null: false
t.string   :country,                   default: "MX"
t.integer  :radius_km,                 default: 25
t.string   :categories,                array: true, default: []
t.boolean  :auto_scan_enabled,         default: false
t.integer  :auto_scan_interval_hours,  default: 24
t.integer  :max_prospects_per_scan,    default: 100
t.timestamps
```

### `PipelineStage`
**Fuente única de verdad para los estados del pipeline.** Los Prospects referencian esta tabla mediante FK.

```ruby
t.string   :name,        null: false
t.integer  :position,    null: false
t.string   :color,       default: "#6366f1"
t.boolean  :is_final,    default: false   # ganado / perdido no se mueven más
t.timestamps
```

**Eliminación de etapas:** `PipelineStage` usa `dependent: :restrict_with_error` — no se puede eliminar una etapa si hay Prospects asignados a ella. La UI muestra el error y sugiere reasignar los prospectos primero.

**Etapas por defecto (db/seeds.rb):**

| position | name | color | is_final |
|---|---|---|---|
| 1 | Nuevo | #6366f1 | false |
| 2 | Revisado | #8b5cf6 | false |
| 3 | Contactado | #f59e0b | false |
| 4 | Llamada Agendada | #f97316 | false |
| 5 | Propuesta Enviada | #3b82f6 | false |
| 6 | En Negociación | #10b981 | false |
| 7 | Ganado | #22c55e | true |
| 8 | Perdido | #ef4444 | true |
| 9 | Pausado | #6b7280 | false |

### `Prospect`
Negocio o empresa encontrada por el agente.

```ruby
t.references :pipeline_stage, null: false, foreign_key: true  # fuente única de estado
t.references :scan_job,       null: true,  foreign_key: true  # nil si fue creado manualmente

t.string   :business_name,       null: false
t.string   :category
t.string   :address
t.string   :city
t.string   :phone
t.string   :email
t.string   :website_url
t.string   :facebook_url
t.string   :instagram_url
t.string   :linkedin_url
t.string   :google_maps_url
t.string   :google_maps_place_id             # índice único para deduplicación de Google Maps
t.string   :source                           # google_maps | manual (en v1 no hay descubrimiento vía redes sociales)
t.text     :notes
t.datetime :found_at
t.timestamps
```

**Índices:**
```ruby
add_index :prospects, :google_maps_place_id, unique: true, where: "google_maps_place_id IS NOT NULL"
add_index :prospects, :pipeline_stage_id
add_index :prospects, :city
add_index :prospects, :found_at
```

**Sin `has_website` ni `website_age_years`.** `has_website` es derivado (`website_url.present?`). `website_age_years` no tiene fuente de datos confirmada en v1.

### `WebAudit`
Resultado de auditoría técnica y SEO. Un Prospect tiene 0 o 1 WebAudit.
**En v1, una re-auditoría sobreescribe el registro existente. No se mantiene historial.**

```ruby
t.references :prospect,           null: false, foreign_key: true, index: { unique: true }
t.boolean  :has_ssl
t.boolean  :is_mobile_friendly
t.decimal  :load_time_seconds
t.integer  :performance_score     # 0-100 (PageSpeed)
t.integer  :seo_score             # 0-100 (PageSpeed)
t.integer  :accessibility_score   # 0-100 (PageSpeed)
t.boolean  :has_meta_title
t.boolean  :has_meta_description
t.boolean  :has_h1
t.integer  :h1_count
t.jsonb    :issues,               default: []
t.jsonb    :ai_analysis           # schema definido abajo
t.jsonb    :raw_pagespeed_data
t.datetime :audited_at
t.timestamps
```

**Schema de `ai_analysis` (jsonb):**
```json
{
  "overall_score": 42,
  "summary": "El sitio carece de etiquetas meta, tiene velocidad de carga deficiente y no está optimizado para móviles.",
  "issues": [
    {
      "category": "seo",
      "severity": "high",
      "description": "No tiene meta description en ninguna página"
    },
    {
      "category": "performance",
      "severity": "medium",
      "description": "Imágenes sin comprimir aumentan tiempo de carga"
    }
  ],
  "recommendations": [
    "Agregar meta description única por página",
    "Comprimir imágenes con WebP",
    "Activar caché del servidor"
  ],
  "copy_analysis": "El titular principal no comunica el beneficio principal al cliente.",
  "cro_analysis": "No hay CTA visible en el primer viewport."
}
```

El Claude API se invoca con `tool_use` (structured output) para garantizar este schema, con `max_tokens: 2048`. Si el parse falla, `ai_analysis` queda en `nil` y `WebAudit` se crea de todas formas con los datos de PageSpeed.

### `Activity`
Log de seguimiento manual. `scheduled_at` y `completed_at` son timestamps pasivos — no generan notificaciones ni recordatorios en v1.

```ruby
t.references :prospect,      null: false, foreign_key: true
t.string   :activity_type    # nota | llamada | email | reunion | otro
t.text     :description
t.datetime :scheduled_at     # opcional, referencia pasiva de cuándo se agendó
t.datetime :completed_at     # opcional, referencia pasiva de cuándo se completó
t.timestamps
```

### `ScanJob`
Historial de ejecuciones del agente.

```ruby
t.references :search_config,  null: false, foreign_key: true
t.string   :trigger           # manual | scheduled
t.string   :status,           default: "pending"   # pending | running | completed | failed
t.integer  :prospects_found,  default: 0
t.integer  :prospects_new,    default: 0
t.text     :error_message
t.datetime :started_at
t.datetime :finished_at
t.timestamps
```

---

## 5. Flujo de Datos y Agentes

### Flujo 1 — Búsqueda de Prospectos

```
[Usuario pulsa "Escanear Ahora" o ScheduledScanJob dispara]
    ↓
[ScanJob creado con status: running, trigger: manual|scheduled]
    ↓
[ProspectSearchJob encolado en Sidekiq queue: "search"]
    ↓
[Apify Actor: compass/crawler-google-places]
    Input: {
      searchString: "#{category} en #{city}",
      maxCrawledPlaces: search_config.max_prospects_per_scan,
      radiusKm: search_config.radius_km,
      language: "es"
    }
    Output por registro: {
      title, address, phone, website, placeId,
      googleMapsUrl, category, rating
    }
    ↓
[Para cada resultado con website presente:]
[Apify Actor: apify/social-media-scraper]
    Input: { urls: [website_url], platforms: ["facebook","instagram","linkedin"] }
    Output: { facebookUrl, instagramUrl, linkedinUrl }
    ↓
[Prospect::DeduplicationService]
    - Google Maps: filtra por google_maps_place_id único (índice único en DB)
    - Manual: sin auto-dedup; se muestra aviso si nombre+ciudad coincide
      usando Postgres pg_trgm: similarity(LOWER(business_name), LOWER(?)) >= 0.8
      dentro del mismo city. Requiere: CREATE EXTENSION pg_trgm en migration.
    ↓
[Crea registros Prospect nuevos en PostgreSQL con scan_job_id]
[Para cada Prospect con website_url: encola WebAuditJob en queue: "audit"]
    ↓
[ScanJob actualiza: status: completed, prospects_found, prospects_new]
    ↓ Turbo::StreamsChannel broadcast_to "scan_jobs"
[Dashboard actualiza contador y mensaje: "X nuevos prospectos encontrados"]
```

Si el job falla a mitad (excepción), los Prospects ya creados se conservan (commits parciales son aceptables). `ScanJob` se marca `failed` con `error_message`. El job no se reintenta automáticamente para evitar duplicados — el usuario puede lanzar otro scan manualmente.

### Flujo 2 — Auditoría Web y SEO

`WebAuditJob` es encolado explícitamente por `ProspectSearchJob` tras crear cada Prospect con `website_url`. No usa callbacks `after_create`.

```
[WebAuditJob(prospect_id) en Sidekiq queue: "audit"]
    ↓ llamadas en paralelo con threads
[Google PageSpeed Insights API]             [Anthropic Claude API]
    GET pagespeedonline/v5/runPagespeed       system: app/ai/skills/seo_audit.md
    ?url=#{website_url}                       user: "Audita este sitio: #{website_url}"
    &strategy=mobile                          tool_use: enforce ai_analysis schema
    &category=performance,seo,accessibility
    ↓                                         ↓
[Extrae: performance_score, seo_score,      [Parsea tool_use response]
 accessibility_score, is_mobile_friendly,    [ai_analysis jsonb]
 load_time, has_meta_title,
 has_meta_description, has_h1, h1_count,
 has_ssl (de URL https://)]
    ↓                                         ↓
    └────────────── merge ────────────────────┘
    ↓
[Upsert WebAudit (crea o sobreescribe si ya existía)]
    ↓ Turbo::StreamsChannel broadcast_to "prospect_#{prospect_id}"
[Card del prospecto actualiza badges de auditoría en tiempo real]
```

Retry policy del job: 3 intentos con backoff exponencial (gestionado por Sidekiq). Si falla las 3 veces, `WebAudit` queda sin crear — el usuario puede re-auditar manualmente desde el detalle del prospecto.

### Flujo 3 — Escaneo Automático (Cron)

```
[Sidekiq-cron verifica SearchConfig con auto_scan_enabled: true]
    ↓ cada auto_scan_interval_hours (mínimo cada 12 horas)
    ↓ límite: máximo 1 auto-scan por día independientemente del intervalo
[Encola ScheduledScanJob]
    ↓
[Ejecuta Flujo 1 completo con trigger: scheduled]
```

### Integración con marketingskills

El repositorio `coreyhaines31/marketingskills` (MIT License — copia de archivos permitida) contiene SKILL.md como prompts de sistema estructurados.

**Skills a integrar (copiados a `app/ai/skills/`):**
- `seo_audit.md` — auditoría técnica SEO
- `page_cro.md` — análisis de conversión y propuesta de valor
- `site_architecture.md` — evaluación de estructura del sitio

`Audit::AiAnalysisService` lee el archivo SKILL.md, lo usa como `system` message del Claude API, y añade un `tool` definition con el schema de `ai_analysis` para forzar output estructurado.

---

## 6. Interfaz del CRM (5 vistas)

### Vista 1 — Dashboard Principal
- Métricas resumen: total prospectos, sin web (`website_url IS NULL`), SEO bajo (`seo_score < 50`), encontrados esta semana
- Estado del último ScanJob (hora, prospectos encontrados, status)
- Botón "Escanear Ahora" — encola `ProspectSearchJob` y actualiza UI vía Turbo
- Actualización en tiempo real del contador de prospectos vía Turbo Streams

### Vista 2 — Lista de Prospectos
- Tabla paginada (Kaminari, 25 por página) con columnas: nombre, teléfono, web/SEO score, etapa del pipeline, fecha
- Filtros: ciudad, tiene/no tiene web, rango de SEO score, categoría, etapa del pipeline
- Búsqueda por nombre de negocio
- Badges visuales por condición: "Sin web", "SEO crítico (<40)", "Sin SSL"

### Vista 3 — Detalle del Prospecto
- Panel izquierdo: datos de contacto completos (nombre, dirección, teléfono, email, web, redes sociales, fuente, fecha de hallazgo)
- Panel derecho: resultados de auditoría web — scores de PageSpeed, issues del `ai_analysis`, botón "Re-auditar"
- Selector de PipelineStage con dropdown
- Sección de seguimiento: log de Activities, formulario "Nueva actividad" inline con Turbo Frame
- Campo de notas con autosave

### Vista 4 — Pipeline Kanban
- Columnas por `PipelineStage` ordenadas por `position`
- Cards arrastrables con SortableJS + Stimulus controller (`drag_controller.js`)
- Al soltar en otra columna: PATCH a `ProspectsController#update` con nuevo `pipeline_stage_id`
- Cards muestran: nombre del negocio, ciudad, issue principal del WebAudit

### Vista 5 — Configuración del Agente
- Formulario de SearchConfig: ciudad, país, radio (km), categorías (tags input), max prospectos por scan
- Toggle de escaneo automático y frecuencia en horas
- Historial de ScanJobs: tabla con fecha, trigger, status, prospectos encontrados/nuevos, error si aplica
- Gestión de PipelineStages: agregar, renombrar, reordenar (SortableJS), cambiar color

---

## 7. Componentes de Backend

### Jobs y Queues (Sidekiq)

| Job | Queue | Trigger | Responsabilidad |
|---|---|---|---|
| `ProspectSearchJob` | `search` | Manual / ScheduledScanJob | Llama Apify, crea Prospects, encola WebAuditJobs |
| `WebAuditJob` | `audit` | Llamado por ProspectSearchJob | Llama PageSpeed + Claude API, crea/actualiza WebAudit |
| `ScheduledScanJob` | `default` | Sidekiq-cron | Verifica config y encola ProspectSearchJob |

**Concurrencia:** queue `search`: 2 workers, queue `audit`: 5 workers, queue `default`: 1 worker.

### Servicios

| Servicio | Responsabilidad |
|---|---|
| `Apify::GoogleMapsService` | Wrapper del actor `compass/crawler-google-places` |
| `Apify::SocialFinderService` | Wrapper del actor `apify/social-media-scraper` |
| `Audit::PageSpeedService` | Llamada a Google PageSpeed Insights API, extrae métricas |
| `Audit::AiAnalysisService` | Llama Anthropic API con SKILL.md como system prompt, usa tool_use para JSON estructurado |
| `Prospect::DeduplicationService` | Filtra por `place_id` (Google Maps) o nombre+ciudad (otras fuentes) |

### Controllers

```
SessionsController      # login / logout
DashboardController     # métricas y estado general
ProspectsController     # index (lista), show (detalle), update (estado, notas)
ActivitiesController    # create, destroy (anidado bajo prospects)
ScanJobsController      # create (lanzar scan manual), index (historial)
SearchConfigsController # show, update (config del agente)
PipelineController      # index (kanban)
PipelineStagesController # create, update, destroy, reorder
WebAuditsController     # create (re-auditar manualmente)
```

---

## 8. Límites y Controles de Costo

| Límite | Valor por defecto | Configurable |
|---|---|---|
| Máx prospectos por scan | 100 | Sí, en SearchConfig |
| Máx auto-scans por día | 1 | No (hardcoded) |
| Intervalo mínimo entre scans | 12 horas | No (hardcoded) |
| Retry de WebAuditJob | 3 intentos | No |

---

## 9. Manejo de Errores

| Escenario | Comportamiento |
|---|---|
| Apify falla o retorna vacío | `ScanJob` → `failed`, error en `error_message`, botón "Reintentar" en UI. Job NO se reencola automáticamente (riesgo de duplicados) |
| PageSpeed API no responde | `WebAudit` creado con campos técnicos en `nil`, análisis IA se intenta de todas formas |
| Anthropic API falla 3 veces | `ai_analysis` queda en `nil`, `WebAudit` se crea con datos de PageSpeed solamente, botón "Re-auditar" disponible |
| Prospecto duplicado (Google Maps) | Ignorado silenciosamente por índice único en `google_maps_place_id` |
| Prospecto duplicado (otras fuentes) | Aviso visual en UI si nombre+ciudad coincide con 80%+ similitud |
| Sin resultados en búsqueda | `ScanJob` → `completed`, `prospects_found: 0`, mensaje informativo en dashboard |
| ScanJob falla a mitad | Prospects ya creados se conservan. `ScanJob` → `failed`. Usuario puede lanzar nuevo scan |

---

## 10. Variables de Entorno

```bash
DATABASE_URL=
REDIS_URL=
APIFY_API_TOKEN=
ANTHROPIC_API_KEY=
ADMIN_EMAIL=
ADMIN_PASSWORD=
GOOGLE_PAGESPEED_API_KEY=   # opcional — tier gratuito funciona sin key (cuota menor)
```

---

## 11. Estructura de Directorios Clave

```
app/
├── ai/
│   └── skills/
│       ├── seo_audit.md          # copiado de marketingskills (MIT)
│       ├── page_cro.md
│       └── site_architecture.md
├── controllers/
│   ├── application_controller.rb  # before_action :require_login
│   ├── sessions_controller.rb
│   ├── dashboard_controller.rb
│   ├── prospects_controller.rb
│   ├── activities_controller.rb
│   ├── scan_jobs_controller.rb
│   ├── search_configs_controller.rb
│   ├── pipeline_controller.rb
│   ├── pipeline_stages_controller.rb
│   └── web_audits_controller.rb
├── jobs/
│   ├── prospect_search_job.rb
│   ├── web_audit_job.rb
│   └── scheduled_scan_job.rb
├── models/
│   ├── user.rb
│   ├── prospect.rb
│   ├── web_audit.rb
│   ├── search_config.rb
│   ├── pipeline_stage.rb
│   ├── activity.rb
│   └── scan_job.rb
├── services/
│   ├── apify/
│   │   ├── google_maps_service.rb
│   │   └── social_finder_service.rb
│   ├── audit/
│   │   ├── page_speed_service.rb
│   │   └── ai_analysis_service.rb
│   └── prospect/
│       └── deduplication_service.rb
└── views/
    ├── sessions/
    ├── dashboard/
    ├── prospects/
    ├── pipeline/
    └── search_configs/

config/
└── sidekiq.yml   # queues: search, audit, default con concurrencias definidas

Procfile           # web: bundle exec puma / worker: bundle exec sidekiq
db/seeds.rb        # User admin + SearchConfig default + PipelineStages por defecto
```

---

## 12. Deploy (Render.com)

- **Web service**: `bundle exec puma -C config/puma.rb`
- **Worker service** (separado): `bundle exec sidekiq -C config/sidekiq.yml`
- **PostgreSQL**: Managed database de Render
- **Redis**: Managed Redis de Render
- **ENV vars**: configuradas en Render dashboard
- Sidekiq-cron configurado en `config/initializers/sidekiq.rb`

---

## 13. Criterios de Éxito

- [ ] El agente encuentra al menos 20 prospectos reales dada una ciudad y radio de 25km
- [ ] Los prospectos sin web se identifican correctamente (`website_url IS NULL`)
- [ ] La auditoría SEO genera un score numérico y mínimo 3 issues accionables por prospecto
- [ ] El dashboard se actualiza en tiempo real sin recargar la página durante un scan
- [ ] El usuario puede mover prospectos entre etapas del pipeline manualmente (lista y kanban)
- [ ] El escaneo automático corre sin intervención del usuario y respeta el límite de 1 por día
- [ ] No se crean prospectos duplicados entre scans sucesivos de la misma área

---

## 14. Fuera de Alcance (v1)

- Autenticación multi-usuario
- Generación automática de propuestas comerciales
- Envío de emails o mensajes desde el CRM
- Integración directa con redes sociales vía OAuth
- Historial de versiones de WebAudit (re-auditoría sobreescribe)
- Recordatorios o notificaciones por actividades agendadas
- App móvil nativa
- Exportación a CSV / PDF
