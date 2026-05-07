# AI Prospector CRM

CRM web construido en Ruby on Rails que usa agentes de IA para descubrir prospectos locales (negocios sin sitio web, con web desactualizada o con SEO deficiente) y generar un expediente completo de cada uno. El seguimiento comercial se hace de forma manual dentro del CRM.

## ¿Qué hace?

- **Búsqueda automática de prospectos** — Agentes que escanean Google Maps y redes sociales buscando negocios locales sin web o con presencia digital deficiente
- **Auditoría web/SEO automática** — Analiza velocidad, mobile-friendly, SSL, meta tags, estructura SEO y genera recomendaciones con IA
- **Pipeline Kanban configurable** — Seguimiento visual del proceso de venta con etapas personalizables
- **Log de actividades** — Registro manual de llamadas, emails y reuniones por prospecto
- **Scans automáticos programados** — Búsqueda de nuevos prospectos en segundo plano según configuración

## Stack

| Capa | Tecnología |
|---|---|
| Framework | Ruby on Rails 7.2 |
| Frontend | Hotwire (Turbo + Stimulus) + Tailwind CSS |
| Base de datos | PostgreSQL |
| Jobs | Sidekiq + Redis |
| Scraping | Apify (Google Maps + Social Media) |
| Auditoría técnica | Google PageSpeed Insights API |
| Auditoría SEO/IA | Anthropic Claude API + marketingskills |
| Deploy | Render.com |

## Instalación local

### Prerequisitos

- Ruby 3.3+
- PostgreSQL
- Redis
- Node.js (para Tailwind)

### Setup

```bash
# Clonar el repositorio
git clone https://github.com/DevClimbers/crm_sales.git
cd crm_sales

# Instalar dependencias
bundle install

# Configurar variables de entorno
cp .env.example .env
# Editar .env con tus credenciales

# Crear y migrar la base de datos
rails db:create db:migrate db:seed

# Iniciar el servidor
bin/dev
```

### Variables de entorno requeridas

```bash
DATABASE_URL=postgresql://localhost/crm_sales_development
REDIS_URL=redis://localhost:6379/0
APIFY_API_TOKEN=          # https://apify.com — crear cuenta y obtener token
ANTHROPIC_API_KEY=        # https://console.anthropic.com
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=changeme123
GOOGLE_PAGESPEED_API_KEY= # Opcional — funciona sin key con cuota reducida
```

### Iniciar servicios

```bash
# Terminal 1: Rails server
rails server

# Terminal 2: Sidekiq (jobs en background)
bundle exec sidekiq -C config/sidekiq.yml
```

O usar `bin/dev` con Procfile si está configurado Foreman.

## Uso

1. Acceder a `http://localhost:3000` e iniciar sesión con las credenciales del seed
2. Ir a **Configuración** → establecer ciudad, radio y categorías de búsqueda
3. Pulsar **Escanear Ahora** desde el Dashboard para iniciar la búsqueda de prospectos
4. Los prospectos aparecen en tiempo real en la lista con su auditoría web
5. Usar el **Pipeline Kanban** para dar seguimiento al proceso de venta

## Arquitectura

```
app/
├── ai/skills/          # Prompts de marketingskills para auditoría SEO/IA
├── jobs/               # ProspectSearchJob, WebAuditJob, ScheduledScanJob
├── services/
│   ├── apify/          # Wrappers para Google Maps y Social Media scrapers
│   ├── audit/          # PageSpeed + Claude AI analysis
│   └── prospect/       # Deduplicación con pg_trgm
└── views/              # Hotwire: Dashboard, Prospectos, Pipeline, Config
```

Ver la documentación completa en:
- **Spec de diseño:** `docs/superpowers/specs/2026-05-06-ai-prospector-crm-design.md`
- **Plan de implementación:** `.omc/plans/2026-05-06-ai-prospector-crm-plan.md`

## Deploy en Render.com

El proyecto incluye `render.yaml` con la configuración completa para:
- Web service (Rails + Puma)
- Worker service (Sidekiq)
- PostgreSQL managed database
- Redis managed instance

## Licencia

MIT
