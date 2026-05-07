# Plan de Implementación — AI Prospector CRM

**Fecha:** 2026-05-06
**Spec:** `docs/superpowers/specs/2026-05-06-ai-prospector-crm-design.md`
**Stack:** Rails 7.2 · Hotwire · PostgreSQL · Redis · Sidekiq · Apify · Anthropic API
**Deploy:** Render.com

---

## Resumen de Requerimientos

CRM de un solo usuario que usa agentes de IA (Apify + Claude API) para descubrir prospectos locales (negocios sin web o con SEO deficiente), auditarlos automáticamente y permitir seguimiento comercial manual en un pipeline Kanban configurable.

---

## Criterios de Aceptación

- [ ] `rails new` genera la app con PostgreSQL, sin Turbolinks legacy
- [ ] `db:migrate && db:seed` crea el usuario admin, la SearchConfig por defecto y las 9 etapas del pipeline
- [ ] `GET /login` permite autenticarse; todas las rutas requieren login (`require_login`)
- [ ] `POST /scan_jobs` crea un ScanJob y encola `ProspectSearchJob` en Sidekiq queue `search`
- [ ] `ProspectSearchJob` llama a Apify `compass/crawler-google-places`, crea Prospects y encola `WebAuditJob` por cada uno con website
- [ ] `WebAuditJob` llama PageSpeed + Claude API en paralelo, crea/sobreescribe `WebAudit`
- [ ] El dashboard muestra contador de prospectos y se actualiza en tiempo real vía Turbo Streams durante un scan activo
- [ ] La vista de lista filtra por ciudad, web/sin-web, rango SEO score, etapa, con paginación Kaminari (25/pág)
- [ ] La vista de detalle muestra todos los datos del prospecto, el resultado de auditoría y el log de actividades
- [ ] El Kanban mueve prospectos entre columnas con drag & drop (SortableJS) y persiste el cambio
- [ ] `ScheduledScanJob` encola un scan automático máximo 1 vez por día respetando `auto_scan_interval_hours`
- [ ] No se crean prospectos duplicados: `place_id` único en DB; pg_trgm para fuzzy match manual
- [ ] Deploy en Render.com con web service + worker dyno separado

---

## Fases de Implementación

---

### Fase 1 — Scaffolding del Proyecto Rails

**Objetivo:** App Rails funcional con PostgreSQL, Hotwire y Tailwind lista para desarrollo.

#### Paso 1.1 — Crear la app Rails
```bash
rails new crm_sales \
  --database=postgresql \
  --skip-test \
  --skip-action-mailer \
  --skip-action-mailbox \
  --skip-action-text \
  --skip-active-storage
```
- Verificar: `rails db:create` corre sin errores

#### Paso 1.2 — Gems requeridas (`Gemfile`)
```ruby
# Core
gem "sidekiq"
gem "sidekiq-cron"
gem "redis"
gem "kaminari"

# APIs externas
gem "anthropic"          # anthropic-ai/anthropic-sdk-ruby
gem "httparty"           # para Apify y PageSpeed

# Frontend
gem "tailwindcss-rails"
gem "importmap-rails"    # ya incluido en Rails 7.2

# Dev
gem "dotenv-rails", groups: [:development, :test]
```

```bash
bundle install
rails tailwindcss:install
```

#### Paso 1.3 — Configurar Sidekiq
Crear `config/sidekiq.yml`:
```yaml
:concurrency: 8
:queues:
  - [search, 2]
  - [audit, 5]
  - [default, 1]
```

Crear `config/initializers/sidekiq.rb`:
```ruby
Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
```

Montar Sidekiq Web en `config/routes.rb`:
```ruby
require "sidekiq/web"
mount Sidekiq::Web => "/sidekiq"
```

#### Paso 1.4 — Configurar Action Cable (para Turbo Streams)
En `config/cable.yml`:
```yaml
production:
  adapter: redis
  url: <%= ENV.fetch("REDIS_URL") %>
development:
  adapter: async
```

#### Paso 1.5 — Variables de entorno
Crear `.env` (gitignored):
```bash
DATABASE_URL=postgresql://localhost/crm_sales_development
REDIS_URL=redis://localhost:6379/0
APIFY_API_TOKEN=
ANTHROPIC_API_KEY=
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=changeme123
GOOGLE_PAGESPEED_API_KEY=
```

Crear `Procfile`:
```
web: bundle exec puma -C config/puma.rb
worker: bundle exec sidekiq -C config/sidekiq.yml
```

**Verificación de la Fase 1:**
- `rails server` arranca sin errores
- `bundle exec sidekiq` conecta a Redis sin errores

---

### Fase 2 — Migraciones y Modelos

**Objetivo:** Esquema completo de base de datos con todos los modelos, asociaciones, validaciones e índices.

#### Paso 2.1 — Habilitar pg_trgm
Crear migración:
```ruby
class EnablePgTrgm < ActiveRecord::Migration[7.2]
  def up
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"
  end
  def down
    execute "DROP EXTENSION IF EXISTS pg_trgm"
  end
end
```

#### Paso 2.2 — Migración: users
```bash
rails g model User email:string password_digest:string
```
Migración:
```ruby
t.string :email, null: false
t.string :password_digest, null: false
add_index :users, :email, unique: true
```

`app/models/user.rb`:
```ruby
class User < ApplicationRecord
  has_secure_password
  validates :email, presence: true, uniqueness: true
end
```
Gem requerida: `bcrypt` (agregar a Gemfile si no está).

#### Paso 2.3 — Migración: pipeline_stages
```bash
rails g model PipelineStage name:string position:integer color:string is_final:boolean
```
`app/models/pipeline_stage.rb`:
```ruby
class PipelineStage < ApplicationRecord
  has_many :prospects, dependent: :restrict_with_error
  validates :name, :position, presence: true
  default_scope { order(:position) }
end
```

#### Paso 2.4 — Migración: search_configs
```bash
rails g model SearchConfig city:string country:string radius_km:integer \
  categories:string auto_scan_enabled:boolean auto_scan_interval_hours:integer \
  max_prospects_per_scan:integer
```
Migración: arrays en `categories`, defaults y null constraints según spec.

`app/models/search_config.rb`:
```ruby
class SearchConfig < ApplicationRecord
  has_many :scan_jobs
  def self.current
    first_or_create!(
      city: "Ciudad de México", country: "MX",
      radius_km: 25, categories: [],
      auto_scan_enabled: false, auto_scan_interval_hours: 24,
      max_prospects_per_scan: 100
    )
  end
end
```

#### Paso 2.5 — Migración: scan_jobs
```bash
rails g model ScanJob search_config:references trigger:string status:string \
  prospects_found:integer prospects_new:integer error_message:text \
  started_at:datetime finished_at:datetime
```
`app/models/scan_job.rb`:
```ruby
class ScanJob < ApplicationRecord
  belongs_to :search_config
  has_many :prospects
  STATUSES = %w[pending running completed failed].freeze
  validates :status, inclusion: { in: STATUSES }
end
```

#### Paso 2.6 — Migración: prospects
```bash
rails g model Prospect pipeline_stage:references scan_job:references \
  business_name:string category:string address:string city:string \
  phone:string email:string website_url:string facebook_url:string \
  instagram_url:string linkedin_url:string google_maps_url:string \
  google_maps_place_id:string source:string notes:text found_at:datetime
```
Añadir en la migración los índices definidos en el spec:
```ruby
add_index :prospects, :google_maps_place_id, unique: true,
          where: "google_maps_place_id IS NOT NULL"
add_index :prospects, :pipeline_stage_id
add_index :prospects, :city
add_index :prospects, :found_at
```
`scan_job` referencia con `null: true`.

`app/models/prospect.rb`:
```ruby
class Prospect < ApplicationRecord
  belongs_to :pipeline_stage
  belongs_to :scan_job, optional: true
  has_one :web_audit, dependent: :destroy
  has_many :activities, dependent: :destroy

  scope :without_website, -> { where(website_url: nil) }
  scope :with_low_seo, -> { joins(:web_audit).where("web_audits.seo_score < 50") }
  scope :found_this_week, -> { where(found_at: 1.week.ago..) }

  def has_website?
    website_url.present?
  end
end
```

#### Paso 2.7 — Migración: web_audits
```bash
rails g model WebAudit prospect:references has_ssl:boolean \
  is_mobile_friendly:boolean load_time_seconds:decimal \
  performance_score:integer seo_score:integer accessibility_score:integer \
  has_meta_title:boolean has_meta_description:boolean has_h1:boolean \
  h1_count:integer issues:jsonb ai_analysis:jsonb raw_pagespeed_data:jsonb \
  audited_at:datetime
```
Índice único en `prospect_id`:
```ruby
add_index :web_audits, :prospect_id, unique: true
```

`app/models/web_audit.rb`:
```ruby
class WebAudit < ApplicationRecord
  belongs_to :prospect
  def critical?
    seo_score.present? && seo_score < 40
  end
end
```

#### Paso 2.8 — Migración: activities
```bash
rails g model Activity prospect:references activity_type:string \
  description:text scheduled_at:datetime completed_at:datetime
```

`app/models/activity.rb`:
```ruby
class Activity < ApplicationRecord
  belongs_to :prospect
  TYPES = %w[nota llamada email reunion otro].freeze
  validates :activity_type, inclusion: { in: TYPES }
  validates :description, presence: true
end
```

#### Paso 2.9 — Seeds (`db/seeds.rb`)
```ruby
User.find_or_create_by!(email: ENV.fetch("ADMIN_EMAIL", "admin@example.com")) do |u|
  u.password = ENV.fetch("ADMIN_PASSWORD", "changeme123")
  u.password_confirmation = ENV.fetch("ADMIN_PASSWORD", "changeme123")
end

SearchConfig.current # crea la config por defecto

stages = [
  { position: 1, name: "Nuevo",            color: "#6366f1", is_final: false },
  { position: 2, name: "Revisado",          color: "#8b5cf6", is_final: false },
  { position: 3, name: "Contactado",        color: "#f59e0b", is_final: false },
  { position: 4, name: "Llamada Agendada",  color: "#f97316", is_final: false },
  { position: 5, name: "Propuesta Enviada", color: "#3b82f6", is_final: false },
  { position: 6, name: "En Negociación",    color: "#10b981", is_final: false },
  { position: 7, name: "Ganado",            color: "#22c55e", is_final: true  },
  { position: 8, name: "Perdido",           color: "#ef4444", is_final: true  },
  { position: 9, name: "Pausado",           color: "#6b7280", is_final: false },
]
stages.each { |attrs| PipelineStage.find_or_create_by!(position: attrs[:position]).update!(attrs) }
```

**Verificación de la Fase 2:**
- `rails db:migrate db:seed` sin errores
- `rails console`: `User.count == 1`, `PipelineStage.count == 9`, `SearchConfig.count == 1`
- `prospect.has_website?` retorna `false` cuando `website_url` es nil

---

### Fase 3 — Autenticación

**Objetivo:** Login funcional con sesión Rails y protección de todas las rutas.

#### Paso 3.1 — ApplicationController
`app/controllers/application_controller.rb`:
```ruby
class ApplicationController < ActionController::Base
  before_action :require_login
  helper_method :current_user

  private

  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end

  def require_login
    redirect_to login_path unless current_user
  end
end
```

#### Paso 3.2 — SessionsController
`app/controllers/sessions_controller.rb`:
```ruby
class SessionsController < ApplicationController
  skip_before_action :require_login

  def new; end

  def create
    user = User.find_by(email: params[:email])
    if user&.authenticate(params[:password])
      session[:user_id] = user.id
      redirect_to root_path
    else
      flash.now[:alert] = "Email o contraseña incorrectos"
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session.delete(:user_id)
    redirect_to login_path
  end
end
```

#### Paso 3.3 — Rutas de sesión (`config/routes.rb`)
```ruby
Rails.application.routes.draw do
  get  "/login",  to: "sessions#new",     as: :login
  post "/login",  to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout

  root "dashboard#index"
  # ... resto de rutas en fases siguientes
end
```

#### Paso 3.4 — Vista de login (`app/views/sessions/new.html.erb`)
Formulario con Tailwind: campos email + password + botón "Iniciar sesión".

**Verificación de la Fase 3:**
- `GET /` sin sesión redirige a `/login`
- Login con credenciales correctas redirige a `/`
- Login con credenciales incorrectas muestra error y re-renderiza el form

---

### Fase 4 — Servicios Externos

**Objetivo:** Wrappers funcionales para Apify, PageSpeed y Claude API.

#### Paso 4.1 — Copiar skills de marketingskills

```bash
mkdir -p app/ai/skills
# Descargar los SKILL.md del repo coreyhaines31/marketingskills
curl -o app/ai/skills/seo_audit.md \
  https://raw.githubusercontent.com/coreyhaines31/marketingskills/main/skills/seo-audit/SKILL.md
curl -o app/ai/skills/page_cro.md \
  https://raw.githubusercontent.com/coreyhaines31/marketingskills/main/skills/page-cro/SKILL.md
curl -o app/ai/skills/site_architecture.md \
  https://raw.githubusercontent.com/coreyhaines31/marketingskills/main/skills/site-architecture/SKILL.md
```

#### Paso 4.2 — `Apify::GoogleMapsService`
`app/services/apify/google_maps_service.rb`:
```ruby
module Apify
  class GoogleMapsService
    ACTOR_ID = "compass~crawler-google-places"
    BASE_URL = "https://api.apify.com/v2"

    def initialize(config)
      @config = config
      @token = ENV.fetch("APIFY_API_TOKEN")
    end

    def search(category:)
      run_id = start_actor_run(category: category)
      poll_until_done(run_id)
      fetch_results(run_id)
    end

    private

    def start_actor_run(category:)
      response = HTTParty.post(
        "#{BASE_URL}/acts/#{ACTOR_ID}/runs",
        headers: { "Authorization" => "Bearer #{@token}", "Content-Type" => "application/json" },
        body: {
          searchString: "#{category} en #{@config.city}",
          maxCrawledPlaces: @config.max_prospects_per_scan,
          language: "es"
        }.to_json
      )
      raise "Apify error: #{response.body}" unless response.success?
      response.parsed_response.dig("data", "id")
    end

    def poll_until_done(run_id)
      120.times do
        status = HTTParty.get("#{BASE_URL}/actor-runs/#{run_id}",
          headers: { "Authorization" => "Bearer #{@token}" })
          .parsed_response.dig("data", "status")
        return if status == "SUCCEEDED"
        raise "Apify run failed: #{status}" if %w[FAILED ABORTED TIMED-OUT].include?(status)
        sleep 5
      end
      raise "Apify run timed out after 10 minutes"
    end

    def fetch_results(run_id)
      response = HTTParty.get(
        "#{BASE_URL}/actor-runs/#{run_id}/dataset/items",
        headers: { "Authorization" => "Bearer #{@token}" }
      )
      response.parsed_response
    end
  end
end
```

#### Paso 4.3 — `Apify::SocialFinderService`
`app/services/apify/social_finder_service.rb`:
```ruby
module Apify
  class SocialFinderService
    ACTOR_ID = "apify~social-media-scraper"
    BASE_URL = "https://api.apify.com/v2"

    def initialize
      @token = ENV.fetch("APIFY_API_TOKEN")
    end

    # Retorna hash: { facebook_url:, instagram_url:, linkedin_url: }
    def find_socials(website_url:)
      run_id = start_run(website_url)
      poll_until_done(run_id)
      parse_results(fetch_results(run_id))
    rescue => e
      Rails.logger.error "SocialFinderService failed: #{e.message}"
      { facebook_url: nil, instagram_url: nil, linkedin_url: nil }
    end

    private

    def start_run(url)
      response = HTTParty.post(
        "#{BASE_URL}/acts/#{ACTOR_ID}/runs",
        headers: { "Authorization" => "Bearer #{@token}", "Content-Type" => "application/json" },
        body: { startUrls: [{ url: url }] }.to_json
      )
      response.parsed_response.dig("data", "id")
    end

    def poll_until_done(run_id)
      60.times do
        status = HTTParty.get("#{BASE_URL}/actor-runs/#{run_id}",
          headers: { "Authorization" => "Bearer #{@token}" })
          .parsed_response.dig("data", "status")
        return if status == "SUCCEEDED"
        break if %w[FAILED ABORTED TIMED-OUT].include?(status)
        sleep 3
      end
    end

    def fetch_results(run_id)
      HTTParty.get("#{BASE_URL}/actor-runs/#{run_id}/dataset/items",
        headers: { "Authorization" => "Bearer #{@token}" }).parsed_response
    end

    def parse_results(results)
      item = Array(results).first || {}
      {
        facebook_url: item["facebookUrl"],
        instagram_url: item["instagramUrl"],
        linkedin_url: item["linkedinUrl"]
      }
    end
  end
end
```

#### Paso 4.4 — `Audit::PageSpeedService`
`app/services/audit/page_speed_service.rb`:
```ruby
module Audit
  class PageSpeedService
    BASE_URL = "https://www.googleapis.com/pagespeedonline/v5/runPagespeed"

    # Retorna hash con métricas técnicas o nil si falla
    def analyze(url:)
      params = {
        url: url,
        strategy: "mobile",
        category: %w[performance seo accessibility].join("&category=")
      }
      params[:key] = ENV["GOOGLE_PAGESPEED_API_KEY"] if ENV["GOOGLE_PAGESPEED_API_KEY"].present?

      response = HTTParty.get(BASE_URL, query: params)
      return nil unless response.success?

      data = response.parsed_response
      extract_metrics(data)
    rescue => e
      Rails.logger.error "PageSpeedService failed for #{url}: #{e.message}"
      nil
    end

    private

    def extract_metrics(data)
      categories = data.dig("lighthouseResult", "categories") || {}
      audits     = data.dig("lighthouseResult", "audits") || {}

      {
        performance_score:    score(categories, "performance"),
        seo_score:            score(categories, "seo"),
        accessibility_score:  score(categories, "accessibility"),
        is_mobile_friendly:   audits.dig("viewport", "score").to_f >= 0.9,
        load_time_seconds:    audits.dig("interactive", "numericValue").to_f / 1000,
        has_meta_title:       audits.dig("document-title", "score").to_f >= 0.9,
        has_meta_description: audits.dig("meta-description", "score").to_f >= 0.9,
        has_h1:               audits.dig("heading-order", "score").to_f >= 0.9,
        h1_count:             1,
        raw_pagespeed_data:   data
      }
    end

    def score(categories, key)
      val = categories.dig(key, "score")
      val ? (val * 100).round : nil
    end
  end
end
```

#### Paso 4.5 — `Audit::AiAnalysisService`
`app/services/audit/ai_analysis_service.rb`:
```ruby
module Audit
  class AiAnalysisService
    SKILL_PATH = Rails.root.join("app/ai/skills/seo_audit.md")
    MODEL = "claude-sonnet-4-6"
    MAX_TOKENS = 2048

    TOOL_DEFINITION = {
      name: "web_audit_result",
      description: "Structured result of the web/SEO audit",
      input_schema: {
        type: "object",
        properties: {
          overall_score:    { type: "integer", minimum: 0, maximum: 100 },
          summary:          { type: "string" },
          issues:           {
            type: "array",
            items: {
              type: "object",
              properties: {
                category:    { type: "string", enum: %w[seo performance accessibility copy cro] },
                severity:    { type: "string", enum: %w[high medium low] },
                description: { type: "string" }
              },
              required: %w[category severity description]
            }
          },
          recommendations: { type: "array", items: { type: "string" } },
          copy_analysis:    { type: "string" },
          cro_analysis:     { type: "string" }
        },
        required: %w[overall_score summary issues recommendations]
      }
    }.freeze

    def initialize
      @client = Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
      @skill_prompt = File.read(SKILL_PATH)
    end

    # Retorna hash ai_analysis o nil si falla
    def analyze(url:)
      response = @client.messages(
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system: @skill_prompt,
        tools: [TOOL_DEFINITION],
        tool_choice: { type: "tool", name: "web_audit_result" },
        messages: [{ role: "user", content: "Audita este sitio web: #{url}" }]
      )

      tool_use = response.content.find { |b| b.type == "tool_use" }
      tool_use&.input
    rescue => e
      Rails.logger.error "AiAnalysisService failed for #{url}: #{e.message}"
      nil
    end
  end
end
```

#### Paso 4.6 — `Prospect::DeduplicationService`
`app/services/prospect/deduplication_service.rb`:
```ruby
module Prospect
  class DeduplicationService
    # Retorna true si el prospecto ya existe
    def duplicate?(place_id:, business_name:, city:)
      return place_id_exists?(place_id) if place_id.present?
      fuzzy_match_exists?(business_name, city)
    end

    private

    def place_id_exists?(place_id)
      ::Prospect.exists?(google_maps_place_id: place_id)
    end

    def fuzzy_match_exists?(business_name, city)
      return false if business_name.blank? || city.blank?
      ::Prospect.where(city: city)
                .where("similarity(LOWER(business_name), LOWER(?)) >= 0.8", business_name)
                .exists?
    end
  end
end
```

**Verificación de la Fase 4:**
- `Audit::PageSpeedService.new.analyze(url: "https://example.com")` retorna hash con scores
- `Audit::AiAnalysisService.new.analyze(url: "https://example.com")` retorna hash con `overall_score`
- `Prospect::DeduplicationService.new.duplicate?(place_id: nil, business_name: "Tacos El Gordo", city: "Monterrey")` retorna `false` cuando no hay match

---

### Fase 5 — Background Jobs

**Objetivo:** Los tres jobs de Sidekiq funcionando con sus flujos completos.

#### Paso 5.1 — `ProspectSearchJob`
`app/jobs/prospect_search_job.rb`:
```ruby
class ProspectSearchJob < ApplicationJob
  queue_as :search

  def perform(scan_job_id)
    scan_job = ScanJob.find(scan_job_id)
    config   = scan_job.search_config
    dedup    = Prospect::DeduplicationService.new
    maps_svc = Apify::GoogleMapsService.new(config)
    social_svc = Apify::SocialFinderService.new
    default_stage = PipelineStage.order(:position).first

    prospects_found = 0
    prospects_new   = 0

    config.categories.each do |category|
      results = maps_svc.search(category: category)

      results.each do |item|
        prospects_found += 1
        place_id     = item["placeId"]
        business_name = item["title"]
        city         = config.city

        next if dedup.duplicate?(place_id: place_id, business_name: business_name, city: city)

        website_url = item["website"]
        socials = website_url.present? ? social_svc.find_socials(website_url: website_url) : {}

        prospect = ::Prospect.create!(
          pipeline_stage: default_stage,
          scan_job:        scan_job,
          business_name:   business_name,
          category:        item["category"] || category,
          address:         item["address"],
          city:            city,
          phone:           item["phone"],
          website_url:     website_url,
          google_maps_url: item["url"],
          google_maps_place_id: place_id,
          source:          "google_maps",
          found_at:        Time.current,
          **socials
        )

        WebAuditJob.perform_later(prospect.id) if prospect.has_website?
        prospects_new += 1
      end
    end

    scan_job.update!(
      status: "completed",
      prospects_found: prospects_found,
      prospects_new: prospects_new,
      finished_at: Time.current
    )

    Turbo::StreamsChannel.broadcast_update_to(
      "scan_jobs",
      target: "dashboard_stats",
      partial: "dashboard/stats"
    )

  rescue => e
    scan_job.update!(status: "failed", error_message: e.message, finished_at: Time.current)
    raise
  end
end
```

#### Paso 5.2 — `WebAuditJob`
`app/jobs/web_audit_job.rb`:
```ruby
class WebAuditJob < ApplicationJob
  queue_as :audit
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(prospect_id)
    prospect   = Prospect.find(prospect_id)
    url        = prospect.website_url
    has_ssl    = url.start_with?("https://")

    pagespeed_result = nil
    ai_result        = nil

    threads = [
      Thread.new { pagespeed_result = Audit::PageSpeedService.new.analyze(url: url) },
      Thread.new { ai_result = Audit::AiAnalysisService.new.analyze(url: url) }
    ]
    threads.each(&:join)

    audit_attrs = {
      has_ssl:       has_ssl,
      ai_analysis:   ai_result,
      audited_at:    Time.current
    }.merge(pagespeed_result || {})

    audit = WebAudit.find_or_initialize_by(prospect: prospect)
    audit.update!(audit_attrs)

    Turbo::StreamsChannel.broadcast_replace_to(
      "prospect_#{prospect_id}",
      target: "web_audit_#{prospect_id}",
      partial: "prospects/web_audit",
      locals: { web_audit: audit }
    )
  end
end
```

#### Paso 5.3 — `ScheduledScanJob`
`app/jobs/scheduled_scan_job.rb`:
```ruby
class ScheduledScanJob < ApplicationJob
  queue_as :default
  MAX_SCANS_PER_DAY = 1

  def perform
    config = SearchConfig.current
    return unless config.auto_scan_enabled

    today_scans = ScanJob.where(trigger: "scheduled")
                         .where("created_at >= ?", Time.current.beginning_of_day)
                         .count
    return if today_scans >= MAX_SCANS_PER_DAY

    last_scan = ScanJob.where(trigger: "scheduled").order(:created_at).last
    min_hours = [config.auto_scan_interval_hours, 12].max
    return if last_scan && last_scan.created_at > min_hours.hours.ago

    scan_job = ScanJob.create!(
      search_config: config,
      trigger: "scheduled",
      status: "running",
      started_at: Time.current
    )
    ProspectSearchJob.perform_later(scan_job.id)
  end
end
```

#### Paso 5.4 — Configurar Sidekiq-cron
En `config/initializers/sidekiq.rb`, añadir:
```ruby
Sidekiq::Cron::Job.load_from_hash(
  "scheduled_scan" => {
    "cron"  => "0 * * * *",   # cada hora — el job decide internamente si correr
    "class" => "ScheduledScanJob"
  }
)
```

**Verificación de la Fase 5:**
- `ProspectSearchJob.perform_now(scan_job.id)` crea Prospects y encola WebAuditJobs (con Apify configurado)
- `WebAuditJob.perform_now(prospect.id)` crea/actualiza `WebAudit`
- `ScheduledScanJob.perform_now` no encola si `auto_scan_enabled: false`
- `ScheduledScanJob.perform_now` no encola si ya hubo 1 scan hoy

---

### Fase 6 — Controllers y Rutas

**Objetivo:** Todos los endpoints REST necesarios para las 5 vistas.

#### Paso 6.1 — Rutas completas (`config/routes.rb`)
```ruby
Rails.application.routes.draw do
  get    "/login",  to: "sessions#new",     as: :login
  post   "/login",  to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout

  root "dashboard#index"

  resources :prospects, only: [:index, :show, :update] do
    resources :activities, only: [:create, :destroy]
    resource  :web_audit,  only: [:create]
  end

  resources :scan_jobs,     only: [:index, :create]
  resource  :search_config, only: [:show, :update]

  resources :pipeline_stages, only: [:create, :update, :destroy] do
    collection { patch :reorder }
  end

  get "/pipeline", to: "pipeline#index", as: :pipeline

  require "sidekiq/web"
  mount Sidekiq::Web => "/sidekiq"
end
```

#### Paso 6.2 — `DashboardController`
`app/controllers/dashboard_controller.rb`:
```ruby
class DashboardController < ApplicationController
  def index
    @total_prospects     = Prospect.count
    @without_website     = Prospect.without_website.count
    @low_seo_count       = Prospect.with_low_seo.count
    @found_this_week     = Prospect.found_this_week.count
    @last_scan           = ScanJob.order(:created_at).last
    @search_config       = SearchConfig.current
  end
end
```

#### Paso 6.3 — `ProspectsController`
```ruby
class ProspectsController < ApplicationController
  def index
    @prospects = Prospect.includes(:pipeline_stage, :web_audit)
                         .filter_by(filter_params)
                         .order(found_at: :desc)
                         .page(params[:page])
    @pipeline_stages = PipelineStage.all
  end

  def show
    @prospect  = Prospect.includes(:web_audit, :activities, :pipeline_stage).find(params[:id])
    @activity  = Activity.new
    @stages    = PipelineStage.all
  end

  def update
    @prospect = Prospect.find(params[:id])
    if @prospect.update(prospect_params)
      respond_to do |fmt|
        fmt.html { redirect_to @prospect }
        fmt.turbo_stream
      end
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def prospect_params
    params.require(:prospect).permit(:pipeline_stage_id, :notes)
  end

  def filter_params
    params.permit(:city, :has_website, :min_seo, :max_seo, :category, :pipeline_stage_id)
  end
end
```

Añadir scope `filter_by` en `Prospect`:
```ruby
scope :filter_by, ->(filters) {
  scope = all
  scope = scope.where(city: filters[:city]) if filters[:city].present?
  scope = scope.without_website if filters[:has_website] == "false"
  scope = scope.where.not(website_url: nil) if filters[:has_website] == "true"
  scope = scope.where(pipeline_stage_id: filters[:pipeline_stage_id]) if filters[:pipeline_stage_id].present?
  scope = scope.joins(:web_audit).where("web_audits.seo_score >= ?", filters[:min_seo]) if filters[:min_seo].present?
  scope = scope.joins(:web_audit).where("web_audits.seo_score <= ?", filters[:max_seo]) if filters[:max_seo].present?
  scope
}
```

#### Paso 6.4 — `ScanJobsController`
```ruby
class ScanJobsController < ApplicationController
  def index
    @scan_jobs = ScanJob.includes(:search_config).order(created_at: :desc).limit(20)
  end

  def create
    config   = SearchConfig.current
    scan_job = ScanJob.create!(
      search_config: config,
      trigger: "manual",
      status: "running",
      started_at: Time.current
    )
    ProspectSearchJob.perform_later(scan_job.id)
    respond_to do |fmt|
      fmt.html { redirect_to root_path, notice: "Scan iniciado" }
      fmt.turbo_stream
    end
  end
end
```

#### Paso 6.5 — `ActivitiesController`
```ruby
class ActivitiesController < ApplicationController
  def create
    @prospect = Prospect.find(params[:prospect_id])
    @activity = @prospect.activities.build(activity_params)
    if @activity.save
      respond_to do |fmt|
        fmt.html { redirect_to @prospect }
        fmt.turbo_stream
      end
    else
      render "prospects/show", status: :unprocessable_entity
    end
  end

  def destroy
    @prospect = Prospect.find(params[:prospect_id])
    @activity = @prospect.activities.find(params[:id])
    @activity.destroy
    respond_to do |fmt|
      fmt.html { redirect_to @prospect }
      fmt.turbo_stream { render turbo_stream: turbo_stream.remove(@activity) }
    end
  end

  private

  def activity_params
    params.require(:activity).permit(:activity_type, :description, :scheduled_at)
  end
end
```

#### Paso 6.6 — `WebAuditsController`
```ruby
class WebAuditsController < ApplicationController
  def create
    @prospect = Prospect.find(params[:prospect_id])
    WebAuditJob.perform_later(@prospect.id)
    redirect_to @prospect, notice: "Re-auditoría en progreso"
  end
end
```

#### Paso 6.7 — `PipelineController` y `PipelineStagesController`
```ruby
class PipelineController < ApplicationController
  def index
    @stages    = PipelineStage.includes(prospects: :web_audit).all
    @prospects = Prospect.includes(:pipeline_stage, :web_audit).all
  end
end

class PipelineStagesController < ApplicationController
  def create
    @stage = PipelineStage.new(stage_params)
    @stage.position = PipelineStage.count + 1
    @stage.save!
    redirect_to search_config_path
  end

  def update
    @stage = PipelineStage.find(params[:id])
    @stage.update!(stage_params)
    redirect_to search_config_path
  end

  def destroy
    @stage = PipelineStage.find(params[:id])
    if @stage.destroy
      redirect_to search_config_path
    else
      redirect_to search_config_path, alert: @stage.errors.full_messages.to_sentence
    end
  end

  def reorder
    params[:ids].each_with_index do |id, index|
      PipelineStage.find(id).update_column(:position, index + 1)
    end
    head :ok
  end

  private

  def stage_params
    params.require(:pipeline_stage).permit(:name, :color)
  end
end
```

#### Paso 6.8 — `SearchConfigsController`
```ruby
class SearchConfigsController < ApplicationController
  def show
    @config        = SearchConfig.current
    @scan_jobs     = ScanJob.order(created_at: :desc).limit(10)
    @stages        = PipelineStage.all
  end

  def update
    @config = SearchConfig.current
    if @config.update(config_params)
      redirect_to search_config_path, notice: "Configuración guardada"
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def config_params
    params.require(:search_config).permit(
      :city, :country, :radius_km, :auto_scan_enabled,
      :auto_scan_interval_hours, :max_prospects_per_scan,
      categories: []
    )
  end
end
```

**Verificación de la Fase 6:**
- `GET /` retorna 200 con métricas del dashboard
- `POST /scan_jobs` crea ScanJob y encola job, retorna redirect o Turbo Stream
- `PATCH /prospects/:id` con `pipeline_stage_id` actualiza el estado del prospecto

---

### Fase 7 — Vistas con Hotwire

**Objetivo:** Las 5 vistas funcionales con Tailwind y actualizaciones en tiempo real.

#### Paso 7.1 — Layout principal
`app/views/layouts/application.html.erb`:
- Navbar con: logo, link a Dashboard, Prospectos, Pipeline, Configuración, Cerrar sesión
- Flash messages con Tailwind (verde para notice, rojo para alert)
- `<%= turbo_include_tags %>` y `<%= stimulus_include_tags %>`

#### Paso 7.2 — Dashboard (`app/views/dashboard/index.html.erb`)
- 4 metric cards: Total, Sin web, SEO bajo, Esta semana
- Sección "Último scan": status badge, fecha, prospectos encontrados
- Botón "Escanear Ahora" (form POST a `/scan_jobs`)
- `<turbo-stream-source src="<%= turbo_stream_from "scan_jobs" %>">` para actualizaciones live
- Partial `_stats.html.erb` con `id="dashboard_stats"` para Turbo replace

#### Paso 7.3 — Lista de Prospectos (`app/views/prospects/index.html.erb`)
- Formulario de filtros (GET, Turbo Frame `id="prospects_filter"`)
- Tabla con `<%= render @prospects %>` (collection partial `_prospect.html.erb`)
- Cada fila: nombre, teléfono, badges (Sin web / SEO score), etapa, fecha, link a detalle
- Paginación Kaminari al final

#### Paso 7.4 — Detalle del Prospecto (`app/views/prospects/show.html.erb`)
- Panel izquierdo: datos de contacto (negocio, dirección, tel, email, web, redes sociales)
- Dropdown de etapa con Turbo Frame (PATCH a `/prospects/:id`)
- Panel derecho: scores de PageSpeed (barras de color), issues del `ai_analysis`, botón "Re-auditar"
- `<turbo-stream-source src="<%= turbo_stream_from "prospect_#{@prospect.id}" %>">` para audit en vivo
- Sección actividades: lista `id="activities"`, formulario inline con Turbo Frame

#### Paso 7.5 — Pipeline Kanban (`app/views/pipeline/index.html.erb`)
- Grid CSS de columnas (`grid-flow-col auto-cols-[280px]`, scroll horizontal)
- Cada columna: header con nombre y color de etapa, lista de cards
- Card: nombre del negocio, ciudad, badge del issue principal
- `data-controller="drag"` con SortableJS

`app/javascript/controllers/drag_controller.js`:
```javascript
import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

export default class extends Controller {
  static values = { stageId: Number }

  connect() {
    this.sortable = new Sortable(this.element, {
      group: "pipeline",
      animation: 150,
      onEnd: this.onEnd.bind(this)
    })
  }

  onEnd(event) {
    const prospectId  = event.item.dataset.prospectId
    const stageId     = event.to.dataset.dragStageIdValue
    fetch(`/prospects/${prospectId}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("[name=csrf-token]").content
      },
      body: JSON.stringify({ prospect: { pipeline_stage_id: stageId } })
    })
  }
}
```

Importar SortableJS en `config/importmap.rb`:
```ruby
pin "sortablejs", to: "https://ga.jspm.io/npm:sortablejs@1.15.0/modular/sortable.esm.js"
```

#### Paso 7.6 — Configuración del Agente (`app/views/search_configs/show.html.erb`)
- Formulario SearchConfig con campos: ciudad, radio, categorías (tags input), max prospectos, toggle auto-scan, frecuencia
- Tabla de ScanJobs recientes con status badges (coloreados), trigger, fechas, prospectos
- Sección PipelineStages: lista reordenable (SortableJS) + formulario "Agregar etapa"

**Verificación de la Fase 7:**
- El dashboard muestra contadores reales desde la DB
- Al pulsar "Escanear Ahora" el botón se deshabilita y aparece un indicador de progreso
- Las actualizaciones Turbo Stream del scan llegan al navegador en tiempo real
- El kanban mueve cards entre columnas y persiste el cambio sin recargar la página

---

### Fase 8 — Integración Final y Pulido

**Objetivo:** Conectar todos los componentes, manejar edge cases y preparar para deploy.

#### Paso 8.1 — Turbo Streams desde jobs

Confirmar que `ProspectSearchJob` y `WebAuditJob` hacen broadcast correcto:
- `ProspectSearchJob` → broadcast a `"scan_jobs"` al completar
- `WebAuditJob` → broadcast a `"prospect_#{prospect_id}"` al completar la auditoría

#### Paso 8.2 — Manejo de errores en UI
- Flash de error cuando ScanJob falla: visible en dashboard
- Badge "Auditoría pendiente" / "Auditoría fallida" en cards sin WebAudit
- Botón "Re-auditar" visible cuando `web_audit.ai_analysis` es nil

#### Paso 8.3 — Autosave de notas en detalle del prospecto
`data-controller="autosave"` Stimulus controller:
```javascript
// Debounced PATCH a /prospects/:id con notes actualizado tras 1s de inactividad
```

#### Paso 8.4 — Tailwind config y estilos
- Paleta de colores para badges de severidad: rojo (high), naranja (medium), gris (low)
- Colores de stages respetando el atributo `color` de cada `PipelineStage`
- Score bars de PageSpeed: verde (>70), naranja (50-70), rojo (<50)

#### Paso 8.5 — seed en desarrollo con datos de prueba
Agregar a `db/seeds.rb` (solo en development):
```ruby
if Rails.env.development?
  stage = PipelineStage.first
  3.times do |i|
    Prospect.find_or_create_by!(google_maps_place_id: "test_#{i}") do |p|
      p.business_name   = "Negocio de Prueba #{i+1}"
      p.city            = "Monterrey"
      p.pipeline_stage  = stage
      p.source          = "google_maps"
      p.found_at        = i.days.ago
    end
  end
end
```

**Verificación de la Fase 8:**
- Flujo completo end-to-end: login → escanear → ver prospectos → auditar → mover en kanban
- Los Turbo Streams actualizan el dashboard sin recargar la página
- El kanban persiste el cambio de etapa tras soltar un card

---

### Fase 9 — Deploy en Render.com

**Objetivo:** App productiva accesible por URL pública.

#### Paso 9.1 — Preparar `render.yaml`
```yaml
services:
  - type: web
    name: crm-sales-web
    env: ruby
    buildCommand: bundle install && bundle exec rails assets:precompile && bundle exec rails db:migrate
    startCommand: bundle exec puma -C config/puma.rb
    envVars:
      - key: RAILS_ENV
        value: production
      - key: SECRET_KEY_BASE
        generateValue: true
      - key: DATABASE_URL
        fromDatabase:
          name: crm-sales-db
          property: connectionString
      - key: REDIS_URL
        fromService:
          name: crm-sales-redis
          type: redis
          property: connectionString
      - key: APIFY_API_TOKEN
        sync: false
      - key: ANTHROPIC_API_KEY
        sync: false
      - key: ADMIN_EMAIL
        sync: false
      - key: ADMIN_PASSWORD
        sync: false

  - type: worker
    name: crm-sales-worker
    env: ruby
    buildCommand: bundle install
    startCommand: bundle exec sidekiq -C config/sidekiq.yml
    envVars:
      - fromGroup: crm-sales-web

databases:
  - name: crm-sales-db
    plan: free

  - type: redis
    name: crm-sales-redis
    plan: free
```

#### Paso 9.2 — Configuración de producción
`config/environments/production.rb`:
- `config.force_ssl = true`
- `config.log_level = :info`
- Assets servidos desde CDN o directamente

`config/puma.rb`:
```ruby
workers ENV.fetch("WEB_CONCURRENCY") { 2 }
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
threads threads_count, threads_count
```

#### Paso 9.3 — Deploy y seed inicial
```bash
# En Render Shell o via deploy hook
rails db:migrate
rails db:seed
```

**Verificación de la Fase 9:**
- App accesible en URL de Render
- Login funciona con ADMIN_EMAIL / ADMIN_PASSWORD configurados en ENV
- Worker dyno conecta a Sidekiq y procesa jobs
- `GET /sidekiq` muestra el dashboard de Sidekiq

---

## Riesgos y Mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| Apify actor cambia su output schema | Media | Alto | Wrapper con parsing defensivo; logs de payload crudo en `error_message` |
| Claude API falla o cambia tool_use format | Baja | Medio | WebAudit se crea de todas formas con datos PageSpeed; botón "Re-auditar" |
| Google Maps Scraper retorna 0 resultados | Media | Medio | ScanJob status `completed` con `prospects_found: 0`; UI muestra sugerencia de cambiar categoría |
| Redis en Render free tier tiene límite de memoria | Media | Alto | Sidekiq usa Redis minimal; configurar `maxmemory-policy allkeys-lru` si se llena |
| pg_trgm no disponible en Render PostgreSQL | Baja | Bajo | La migración usa `CREATE EXTENSION IF NOT EXISTS` — falla silenciosamente; dedup solo usa place_id |

---

## Orden Recomendado de Implementación

```
Fase 1 (Setup)
    → Fase 2 (Modelos)
    → Fase 3 (Auth)
    → Fase 4 (Servicios externos)   ← validar con API keys reales
    → Fase 5 (Jobs)
    → Fase 6 (Controllers)
    → Fase 7 (Vistas)
    → Fase 8 (Integración)
    → Fase 9 (Deploy)
```

Cada fase es desplegable independientemente. La Fase 4 requiere API keys de Apify y Anthropic para validar correctamente.

---

## Estimado de Tiempo

| Fase | Estimado |
|---|---|
| 1 — Setup | 2-3 horas |
| 2 — Modelos | 3-4 horas |
| 3 — Auth | 1-2 horas |
| 4 — Servicios | 4-6 horas |
| 5 — Jobs | 3-4 horas |
| 6 — Controllers | 3-4 horas |
| 7 — Vistas | 6-8 horas |
| 8 — Integración | 2-3 horas |
| 9 — Deploy | 1-2 horas |
| **Total** | **~25-36 horas** |
