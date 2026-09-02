-- ============================================================================
-- Multi-Servis - UNIFIED PostgreSQL Schema
-- Wersja: 2.0 FINAL TARGET
--
-- Jedna baza PostgreSQL dla:
--   * aplikacji Android Multi-Servis (przyjecia serwisowe)
--   * Multi-Servis Assist STANDARD / PRO
--   * monitoringu, alertow i powiadomien
--   * licencjonowania
--   * integracji z Breeze
--   * rozmow, nagran, OCR, opinii Google i raportow wlasciciela
--
-- UWAGA:
-- To jest FINALNY SCHEMAT DO NOWEJ / ODTWORZONEJ BAZY.
-- Skrypt usuwa schematy core/service/assist/breeze/config oraz widoki zgodnosci
-- w public. NIE uruchamiaj go na bazie z danymi bez kopii zapasowej i migracji.
-- ============================================================================

BEGIN;

-- Zabezpieczenie przed przypadkowym uruchomieniem na obecnej bazie v1.1.
-- Jesli istnieja stare tabele public.clients/public.licenses, skrypt przerwie sie
-- zanim cokolwiek zmieni. Do istniejacej bazy nalezy uzyc migracji.
DO $$
BEGIN
    IF to_regclass('public.clients') IS NOT NULL
       OR to_regclass('public.licenses') IS NOT NULL
       OR to_regclass('public.assist_installations') IS NOT NULL THEN
        RAISE EXCEPTION 'Wykryto istniejaca baze Multi-Servis v1.x. Nie uruchamiaj schema_final.sql na zywej bazie; najpierw migracja/backup.';
    END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ----------------------------------------------------------------------------
-- SCHEMATY LOGICZNE
-- ----------------------------------------------------------------------------
DROP SCHEMA IF EXISTS service CASCADE;
DROP SCHEMA IF EXISTS assist CASCADE;
DROP SCHEMA IF EXISTS breeze CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;
DROP SCHEMA IF EXISTS config CASCADE;

CREATE SCHEMA core;
CREATE SCHEMA service;
CREATE SCHEMA assist;
CREATE SCHEMA breeze;
CREATE SCHEMA config;

COMMENT ON SCHEMA core IS 'Wspolne dane: uzytkownicy, klienci, telefony, urzadzenia, pliki, rozmowy.';
COMMENT ON SCHEMA service IS 'Przyjecia serwisowe Android/WWW, notatki, OCR, media, finanse i statusy.';
COMMENT ON SCHEMA assist IS 'Multi-Servis Assist: instalacje, telemetria, alerty, licencje, powiadomienia.';
COMMENT ON SCHEMA breeze IS 'Warstwa integracyjna z Breeze; techniczna baza Breeze moze pozostac osobno.';
COMMENT ON SCHEMA config IS 'Ustawienia globalne systemu Multi-Servis.';

-- ----------------------------------------------------------------------------
-- ENUMY
-- ----------------------------------------------------------------------------
CREATE TYPE core.app_role AS ENUM ('OWNER', 'ADMIN', 'RECEPTION', 'TECHNICIAN', 'READONLY');
CREATE TYPE core.call_direction AS ENUM ('INCOMING', 'OUTGOING', 'UNKNOWN');
CREATE TYPE core.archive_rule_type AS ENUM ('ARCHIVE_ALWAYS', 'DO_NOT_ARCHIVE');

CREATE TYPE service.reception_status AS ENUM (
    'IN_SERVICE',
    'READY_FOR_PICKUP',
    'COMPLETED',
    'CANCELLED'
);

CREATE TYPE service.media_kind AS ENUM (
    'DEVICE_LABEL',
    'INTAKE_PHOTO',
    'REPAIR_PHOTO',
    'RELEASE_PHOTO',
    'CALL_RECORDING',
    'DOCUMENT',
    'OTHER'
);

CREATE TYPE service.note_visibility AS ENUM ('STAFF', 'OWNER_ONLY');
CREATE TYPE service.cost_item_type AS ENUM ('LABOR', 'PART', 'DIAGNOSIS', 'SHIPPING', 'DISCOUNT', 'OTHER');
CREATE TYPE service.payment_method AS ENUM ('CASH', 'CARD', 'TRANSFER', 'BLIK', 'OTHER');
CREATE TYPE service.review_status AS ENUM ('PENDING', 'VERIFIED', 'REJECTED');

CREATE TYPE assist.license_tier AS ENUM ('STANDARD', 'PRO');
CREATE TYPE assist.license_status AS ENUM ('ACTIVE', 'EXPIRED', 'REVOKED', 'PENDING');
CREATE TYPE assist.agent_alert_severity AS ENUM ('INFO', 'WARNING', 'CRITICAL');

-- ----------------------------------------------------------------------------
-- FUNKCJE WSPOLNE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.normalize_phone(p_input TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v TEXT;
    digits TEXT;
BEGIN
    IF p_input IS NULL THEN
        RETURN NULL;
    END IF;

    v := trim(p_input);
    IF v = '' THEN
        RETURN NULL;
    END IF;

    -- Zachowujemy +, reszte znakow usuwamy.
    v := regexp_replace(v, '[^0-9+]', '', 'g');

    IF left(v, 2) = '00' THEN
        v := '+' || substr(v, 3);
    END IF;

    -- Dla numerow bez prefiksu: polski numer 9-cyfrowy -> +48.
    IF left(v, 1) <> '+' THEN
        digits := regexp_replace(v, '[^0-9]', '', 'g');
        IF length(digits) = 9 THEN
            v := '+48' || digits;
        ELSE
            v := '+' || digits;
        END IF;
    END IF;

    IF v !~ '^\+[0-9]{7,15}$' THEN
        RAISE EXCEPTION 'Invalid phone number: %', p_input;
    END IF;

    RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION core.phone_match_key(p_input TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v TEXT;
BEGIN
    IF p_input IS NULL THEN RETURN NULL; END IF;
    v := regexp_replace(p_input, '[^0-9]', '', 'g');
    IF v = '' THEN RETURN NULL; END IF;
    -- Zgodnie z ustaleniem aplikacji: dla polskich numerow porownujemy ostatnie 9 cyfr.
    IF length(v) >= 9 THEN
        RETURN right(v, 9);
    END IF;
    RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION core.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION core.parse_call_recording_filename(p_filename TEXT)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_name TEXT;
    v_match TEXT[];
    v_phone TEXT;
    v_stamp TEXT;
    v_ts TIMESTAMP;
BEGIN
    v_name := regexp_replace(p_filename, '\.[^.]+$', '');
    v_match := regexp_match(v_name, '^(\+[0-9]{7,15})-([0-9]{10})$');

    IF v_match IS NULL THEN
        RETURN jsonb_build_object('valid', false, 'filename', p_filename);
    END IF;

    v_phone := v_match[1];
    v_stamp := v_match[2];
    v_ts := to_timestamp(v_stamp, 'YYMMDDHH24MI');

    RETURN jsonb_build_object(
        'valid', true,
        'phone_e164', v_phone,
        'started_at', to_char(v_ts, 'YYYY-MM-DD"T"HH24:MI:SS')
    );
END;
$$;

-- ============================================================================
-- CORE: UZYTKOWNICY
-- ============================================================================
CREATE TABLE core.app_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    email TEXT,
    role core.app_role NOT NULL DEFAULT 'RECEPTION',
    password_hash TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at TIMESTAMPTZ
);

CREATE TRIGGER trg_app_users_updated_at
BEFORE UPDATE ON core.app_users
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

-- ============================================================================
-- CORE: TELEFONY I KLIENCI
-- ============================================================================
CREATE TABLE core.phone_numbers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    e164 TEXT NOT NULL UNIQUE,
    match_key TEXT GENERATED ALWAYS AS (core.phone_match_key(e164)) STORED,
    display_number TEXT,
    first_seen_at TIMESTAMPTZ,
    last_seen_at TIMESTAMPTZ,
    source TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (e164 ~ '^\+[0-9]{7,15}$')
);

CREATE INDEX idx_phone_numbers_match_key ON core.phone_numbers(match_key);

CREATE TRIGGER trg_phone_numbers_updated_at
BEFORE UPDATE ON core.phone_numbers
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE core.clients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name TEXT,
    first_name TEXT,
    last_name TEXT,
    company_name TEXT,
    email TEXT,
    address TEXT,
    notes TEXT,
    google_review BOOLEAN NOT NULL DEFAULT FALSE, -- legacy zgodnosc; szczegoly sa w service.review_rewards
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at TIMESTAMPTZ,
    created_by UUID REFERENCES core.app_users(id),
    updated_by UUID REFERENCES core.app_users(id)
);

CREATE INDEX idx_clients_display_name ON core.clients(display_name);

CREATE TRIGGER trg_clients_updated_at
BEFORE UPDATE ON core.clients
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE core.client_phones (
    client_id UUID NOT NULL REFERENCES core.clients(id) ON DELETE CASCADE,
    phone_number_id UUID NOT NULL REFERENCES core.phone_numbers(id) ON DELETE RESTRICT,
    label TEXT,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (client_id, phone_number_id)
);

CREATE INDEX idx_client_phones_phone ON core.client_phones(phone_number_id);
CREATE UNIQUE INDEX uq_client_primary_phone
ON core.client_phones(client_id)
WHERE is_primary = TRUE;

-- Notatki przy numerze i reguly importu/archiwizacji.
CREATE TABLE core.phone_archive_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_number_id UUID NOT NULL REFERENCES core.phone_numbers(id) ON DELETE CASCADE,
    rule_type core.archive_rule_type NOT NULL,
    note TEXT,
    created_by UUID REFERENCES core.app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (phone_number_id, rule_type)
);

CREATE TRIGGER trg_phone_archive_rules_updated_at
BEFORE UPDATE ON core.phone_archive_rules
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE core.caller_notes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_number_id UUID NOT NULL REFERENCES core.phone_numbers(id) ON DELETE CASCADE,
    client_id UUID REFERENCES core.clients(id) ON DELETE SET NULL,
    note_text TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    visible_to_reception BOOLEAN NOT NULL DEFAULT TRUE,
    created_by UUID REFERENCES core.app_users(id),
    updated_by UUID REFERENCES core.app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_caller_notes_phone_active
ON core.caller_notes(phone_number_id, is_active);

CREATE TRIGGER trg_caller_notes_updated_at
BEFORE UPDATE ON core.caller_notes
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

-- ============================================================================
-- CORE: URZADZENIA - wspolne dla serwisu i Assist
-- ============================================================================
CREATE TABLE core.devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID REFERENCES core.clients(id) ON DELETE SET NULL,
    device_type TEXT,
    manufacturer TEXT,
    model TEXT,
    serial_number TEXT,
    serial_normalized TEXT,
    hostname TEXT,
    os TEXT,
    os_version TEXT,
    description TEXT,
    tactical_agent_id TEXT,        -- legacy / zgodnosc z istniejacym systemem
    rustdesk_id TEXT,              -- legacy / nieuzywane docelowo; pozostawione dla zgodnosci danych
    breeze_device_id TEXT,         -- docelowy identyfikator Breeze
    last_seen TIMESTAMPTZ,
    is_online BOOLEAN DEFAULT FALSE,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at TIMESTAMPTZ,
    created_by UUID REFERENCES core.app_users(id),
    updated_by UUID REFERENCES core.app_users(id)
);

CREATE INDEX idx_devices_client ON core.devices(client_id);
CREATE INDEX idx_devices_serial_normalized ON core.devices(serial_normalized);
CREATE INDEX idx_devices_tactical_agent_id ON core.devices(tactical_agent_id);
CREATE INDEX idx_devices_breeze_device_id ON core.devices(breeze_device_id);

CREATE TRIGGER trg_devices_updated_at
BEFORE UPDATE ON core.devices
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

-- ============================================================================
-- CORE: MAGAZYN PLIKOW / OBIEKTOW
-- ============================================================================
CREATE TABLE core.storage_objects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    storage_area TEXT NOT NULL DEFAULT 'media',
    object_key TEXT NOT NULL UNIQUE,
    original_filename TEXT,
    mime_type TEXT,
    extension TEXT,
    size_bytes BIGINT,
    sha256 CHAR(64),
    captured_at TIMESTAMPTZ,
    uploaded_at TIMESTAMPTZ,
    upload_completed BOOLEAN NOT NULL DEFAULT FALSE,
    created_by UUID REFERENCES core.app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES core.app_users(id)
);

CREATE INDEX idx_storage_objects_sha256 ON core.storage_objects(sha256);
CREATE INDEX idx_storage_objects_created ON core.storage_objects(created_at DESC);

-- ============================================================================
-- SERVICE: CENTRALNY NUMER PRZYJECIA
-- Format: 11/DD/MM/YY, 12/DD/MM/YY...; kazdy dzien zaczyna sie od 11.
-- ============================================================================
CREATE TABLE service.reception_daily_counters (
    reception_date DATE PRIMARY KEY,
    last_sequence INTEGER NOT NULL CHECK (last_sequence >= 11),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION service.next_reception_number(p_received_at TIMESTAMPTZ DEFAULT now())
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_date DATE;
    v_seq INTEGER;
BEGIN
    v_date := (p_received_at AT TIME ZONE 'Europe/Warsaw')::DATE;

    INSERT INTO service.reception_daily_counters(reception_date, last_sequence, updated_at)
    VALUES (v_date, 11, now())
    ON CONFLICT (reception_date)
    DO UPDATE SET
        last_sequence = service.reception_daily_counters.last_sequence + 1,
        updated_at = now()
    RETURNING last_sequence INTO v_seq;

    RETURN lpad(v_seq::TEXT, 2, '0') || '/' || to_char(v_date, 'DD/MM/YY');
END;
$$;

-- ============================================================================
-- SERVICE: PRZYJECIA
-- ============================================================================
CREATE TABLE service.service_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    reception_number TEXT NOT NULL UNIQUE,
    order_number BIGSERIAL UNIQUE, -- techniczny legacy numer; nie pokazujemy klientowi

    client_id UUID REFERENCES core.clients(id) ON DELETE SET NULL,
    primary_phone_id UUID NOT NULL REFERENCES core.phone_numbers(id) ON DELETE RESTRICT,
    secondary_phone_id UUID REFERENCES core.phone_numbers(id) ON DELETE RESTRICT,
    device_id UUID REFERENCES core.devices(id) ON DELETE SET NULL,

    status service.reception_status NOT NULL DEFAULT 'IN_SERVICE',

    intake_description TEXT,
    fault_description TEXT,
    accessories_received TEXT,
    technician_notes TEXT,
    customer_notes TEXT,

    estimated_cost NUMERIC(12,2),
    final_cost NUMERIC(12,2),
    currency CHAR(3) NOT NULL DEFAULT 'PLN',

    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ready_at TIMESTAMPTZ,
    client_notified_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    released_at TIMESTAMPTZ, -- legacy alias biznesowy; moze byc rowny completed_at

    cancelled_at TIMESTAMPTZ,
    cancellation_reason TEXT,
    cancelled_by UUID REFERENCES core.app_users(id),

    received_by UUID REFERENCES core.app_users(id),
    assigned_to UUID REFERENCES core.app_users(id),
    updated_by UUID REFERENCES core.app_users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at TIMESTAMPTZ,

    CHECK (secondary_phone_id IS NULL OR secondary_phone_id <> primary_phone_id),
    CHECK (
        status <> 'CANCELLED'
        OR (cancellation_reason IS NOT NULL AND btrim(cancellation_reason) <> '')
    )
);

CREATE OR REPLACE FUNCTION service.set_reception_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.reception_number IS NULL OR btrim(NEW.reception_number) = '' THEN
        NEW.reception_number := service.next_reception_number(COALESCE(NEW.received_at, now()));
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_service_orders_number
BEFORE INSERT ON service.service_orders
FOR EACH ROW EXECUTE FUNCTION service.set_reception_number();

CREATE OR REPLACE FUNCTION service.set_service_order_lifecycle_timestamps()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status = 'READY_FOR_PICKUP' AND NEW.ready_at IS NULL THEN
        NEW.ready_at := now();
    END IF;

    IF NEW.status = 'COMPLETED' AND NEW.completed_at IS NULL THEN
        NEW.completed_at := now();
        NEW.released_at := COALESCE(NEW.released_at, NEW.completed_at);
    END IF;

    IF NEW.status = 'CANCELLED' AND NEW.cancelled_at IS NULL THEN
        NEW.cancelled_at := now();
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_service_orders_lifecycle
BEFORE INSERT OR UPDATE OF status ON service.service_orders
FOR EACH ROW EXECUTE FUNCTION service.set_service_order_lifecycle_timestamps();

CREATE TRIGGER trg_service_orders_updated_at
BEFORE UPDATE ON service.service_orders
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE INDEX idx_service_orders_phone ON service.service_orders(primary_phone_id);
CREATE INDEX idx_service_orders_second_phone ON service.service_orders(secondary_phone_id);
CREATE INDEX idx_service_orders_client ON service.service_orders(client_id);
CREATE INDEX idx_service_orders_device ON service.service_orders(device_id);
CREATE INDEX idx_service_orders_status ON service.service_orders(status);
CREATE INDEX idx_service_orders_received_at ON service.service_orders(received_at DESC);
CREATE INDEX idx_service_orders_reception_number ON service.service_orders(reception_number);

-- Historia statusu: nawet anulowanie nie usuwa rekordu ani numeru.
CREATE TABLE service.service_order_status_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service.service_orders(id) ON DELETE CASCADE,
    old_status service.reception_status,
    new_status service.reception_status NOT NULL,
    note TEXT,
    changed_by UUID REFERENCES core.app_users(id),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_order_status_history_order
ON service.service_order_status_history(service_order_id, changed_at DESC);

CREATE OR REPLACE FUNCTION service.audit_service_order_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO service.service_order_status_history(service_order_id, old_status, new_status, changed_by)
        VALUES (NEW.id, NULL, NEW.status, NEW.received_by);
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO service.service_order_status_history(service_order_id, old_status, new_status, changed_by)
        VALUES (NEW.id, OLD.status, NEW.status, COALESCE(NEW.cancelled_by, NEW.updated_by, NEW.assigned_to, NEW.received_by));
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_service_orders_status_history
AFTER INSERT OR UPDATE OF status ON service.service_orders
FOR EACH ROW EXECUTE FUNCTION service.audit_service_order_status();

-- ============================================================================
-- SERVICE: NOTATKI DO SPRAWY
-- ============================================================================
CREATE TABLE service.service_order_notes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service.service_orders(id) ON DELETE CASCADE,
    note_text TEXT NOT NULL CHECK (btrim(note_text) <> ''),
    visibility service.note_visibility NOT NULL DEFAULT 'STAFF',
    created_by UUID REFERENCES core.app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES core.app_users(id)
);

CREATE INDEX idx_service_order_notes_order
ON service.service_order_notes(service_order_id, created_at DESC);

CREATE TRIGGER trg_service_order_notes_updated_at
BEFORE UPDATE ON service.service_order_notes
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

-- ============================================================================
-- SERVICE: MEDIA / ZDJECIA
-- ============================================================================
CREATE TABLE service.service_order_media (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service.service_orders(id) ON DELETE CASCADE,
    storage_object_id UUID NOT NULL REFERENCES core.storage_objects(id) ON DELETE RESTRICT,
    media_kind service.media_kind NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    caption TEXT,
    is_source_of_truth BOOLEAN NOT NULL DEFAULT FALSE,
    created_by UUID REFERENCES core.app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES core.app_users(id),
    UNIQUE(service_order_id, storage_object_id)
);

CREATE INDEX idx_service_order_media_order
ON service.service_order_media(service_order_id, media_kind, sort_order);

-- ============================================================================
-- SERVICE: OCR
-- ============================================================================
CREATE TABLE service.ocr_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID REFERENCES service.service_orders(id) ON DELETE CASCADE,
    device_id UUID REFERENCES core.devices(id) ON DELETE SET NULL,
    source_media_id UUID NOT NULL REFERENCES service.service_order_media(id) ON DELETE RESTRICT,
    engine_name TEXT NOT NULL DEFAULT 'ML_KIT_TEXT_RECOGNITION',
    engine_version TEXT,
    parser_version TEXT NOT NULL DEFAULT '1',
    raw_text TEXT,
    detected_manufacturer TEXT,
    detected_model TEXT,
    detected_serial_number TEXT,
    confidence_model NUMERIC(5,4),
    confidence_serial NUMERIC(5,4),
    success BOOLEAN NOT NULL DEFAULT TRUE,
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES core.app_users(id)
);

CREATE INDEX idx_ocr_runs_order ON service.ocr_runs(service_order_id, created_at DESC);
CREATE INDEX idx_ocr_runs_media ON service.ocr_runs(source_media_id);

CREATE TABLE service.device_data_corrections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID NOT NULL REFERENCES core.devices(id) ON DELETE CASCADE,
    service_order_id UUID REFERENCES service.service_orders(id) ON DELETE SET NULL,
    field_name TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT,
    reason TEXT,
    corrected_by UUID REFERENCES core.app_users(id),
    corrected_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_device_data_corrections_device
ON service.device_data_corrections(device_id, corrected_at DESC);

-- ============================================================================
-- CORE: ROZMOWY + NAGRANIA
-- ============================================================================
CREATE TABLE core.calls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_number_id UUID NOT NULL REFERENCES core.phone_numbers(id) ON DELETE RESTRICT,
    client_id UUID REFERENCES core.clients(id) ON DELETE SET NULL,
    service_order_id UUID REFERENCES service.service_orders(id) ON DELETE SET NULL,
    direction core.call_direction NOT NULL DEFAULT 'UNKNOWN',
    started_at TIMESTAMPTZ NOT NULL,
    duration_seconds INTEGER,
    source TEXT NOT NULL DEFAULT 'ANDROID_DIALER',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (duration_seconds IS NULL OR duration_seconds >= 0)
);

CREATE INDEX idx_calls_phone_started ON core.calls(phone_number_id, started_at DESC);
CREATE INDEX idx_calls_client_started ON core.calls(client_id, started_at DESC);
CREATE INDEX idx_calls_order ON core.calls(service_order_id, started_at DESC);

CREATE TRIGGER trg_calls_updated_at
BEFORE UPDATE ON core.calls
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE core.call_recordings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    call_id UUID NOT NULL REFERENCES core.calls(id) ON DELETE CASCADE,
    storage_object_id UUID NOT NULL REFERENCES core.storage_objects(id) ON DELETE RESTRICT,
    original_filename TEXT NOT NULL,
    parsed_phone_e164 TEXT,
    parsed_started_at TIMESTAMPTZ,
    import_source TEXT,
    imported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(storage_object_id)
);

CREATE INDEX idx_call_recordings_call ON core.call_recordings(call_id);
CREATE INDEX idx_call_recordings_filename ON core.call_recordings(original_filename);

CREATE TABLE core.call_transcripts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    call_recording_id UUID NOT NULL REFERENCES core.call_recordings(id) ON DELETE CASCADE,
    engine_name TEXT,
    engine_version TEXT,
    language_code TEXT DEFAULT 'pl-PL',
    transcript_text TEXT NOT NULL,
    summary_text TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES core.app_users(id)
);

CREATE INDEX idx_call_transcripts_recording ON core.call_transcripts(call_recording_id);

-- ============================================================================
-- SERVICE: FINANSE WLASCICIELA
-- ============================================================================
CREATE TABLE service.owner_finances (
    service_order_id UUID PRIMARY KEY REFERENCES service.service_orders(id) ON DELETE CASCADE,
    service_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (service_amount >= 0),
    material_cost NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (material_cost >= 0),
    donor_material_value NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (donor_material_value >= 0),
    created_by UUID REFERENCES core.app_users(id),
    updated_by UUID REFERENCES core.app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_owner_finances_updated_at
BEFORE UPDATE ON service.owner_finances
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE VIEW service.v_owner_profit AS
SELECT
    so.id AS service_order_id,
    so.reception_number,
    so.received_at,
    COALESCE(ofi.service_amount, 0)::NUMERIC(12,2) AS service_amount,
    COALESCE(ofi.material_cost, 0)::NUMERIC(12,2) AS material_cost,
    COALESCE(ofi.donor_material_value, 0)::NUMERIC(12,2) AS donor_material_value,
    (COALESCE(ofi.service_amount, 0) - COALESCE(ofi.material_cost, 0))::NUMERIC(12,2) AS actual_profit,
    (COALESCE(ofi.service_amount, 0) - COALESCE(ofi.material_cost, 0) - COALESCE(ofi.donor_material_value, 0))::NUMERIC(12,2) AS economic_profit
FROM service.service_orders so
LEFT JOIN service.owner_finances ofi ON ofi.service_order_id = so.id;

-- Zachowane bardziej rozbudowane pozycje kosztowe / platnosci z v1.1.
CREATE TABLE service.service_order_cost_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service.service_orders(id) ON DELETE CASCADE,
    item_type service.cost_item_type NOT NULL,
    description TEXT NOT NULL,
    quantity NUMERIC(12,3) NOT NULL DEFAULT 1,
    unit_price NUMERIC(12,2) NOT NULL DEFAULT 0,
    vat_rate NUMERIC(5,2),
    amount NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    created_by UUID REFERENCES core.app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_cost_items_order ON service.service_order_cost_items(service_order_id);
CREATE TRIGGER trg_cost_items_updated_at
BEFORE UPDATE ON service.service_order_cost_items
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE service.customer_approvals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service.service_orders(id) ON DELETE CASCADE,
    approved BOOLEAN NOT NULL,
    approved_amount NUMERIC(12,2),
    approval_channel TEXT,
    note TEXT,
    approved_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    recorded_by UUID REFERENCES core.app_users(id)
);

CREATE INDEX idx_customer_approvals_order
ON service.customer_approvals(service_order_id, approved_at DESC);

CREATE TABLE service.payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service.service_orders(id) ON DELETE CASCADE,
    amount NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    currency CHAR(3) NOT NULL DEFAULT 'PLN',
    method service.payment_method NOT NULL,
    reference TEXT,
    paid_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    received_by UUID REFERENCES core.app_users(id),
    note TEXT
);

CREATE INDEX idx_payments_order ON service.payments(service_order_id, paid_at DESC);

-- ============================================================================
-- SERVICE: OPINIE GOOGLE + RABATY
-- Brak wiersza = status "Brak" w aplikacji.
-- ============================================================================
CREATE TABLE service.review_rewards (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID REFERENCES core.clients(id) ON DELETE SET NULL,
    phone_number_id UUID NOT NULL REFERENCES core.phone_numbers(id) ON DELETE CASCADE,
    platform TEXT NOT NULL DEFAULT 'GOOGLE',
    reviewer_display_name TEXT,
    review_reference TEXT,
    status service.review_status NOT NULL DEFAULT 'PENDING',
    discount_percent NUMERIC(5,2) NOT NULL DEFAULT 10.00
        CHECK (discount_percent >= 0 AND discount_percent <= 100),
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    verified_at TIMESTAMPTZ,
    verified_by UUID REFERENCES core.app_users(id),
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_review_rewards_phone ON service.review_rewards(phone_number_id, status);
CREATE TRIGGER trg_review_rewards_updated_at
BEFORE UPDATE ON service.review_rewards
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE service.service_order_discounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service.service_orders(id) ON DELETE CASCADE,
    review_reward_id UUID REFERENCES service.review_rewards(id) ON DELETE SET NULL,
    discount_percent NUMERIC(5,2),
    discount_amount NUMERIC(12,2),
    reason TEXT,
    applied_by UUID REFERENCES core.app_users(id),
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- CORE: SMS / WIADOMOSCI - potrzebne do kojarzenia opinii Google i klienta
-- ============================================================================
CREATE TABLE core.sms_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_number_id UUID NOT NULL REFERENCES core.phone_numbers(id) ON DELETE RESTRICT,
    client_id UUID REFERENCES core.clients(id) ON DELETE SET NULL,
    service_order_id UUID REFERENCES service.service_orders(id) ON DELETE SET NULL,
    direction core.call_direction NOT NULL DEFAULT 'UNKNOWN',
    message_text TEXT NOT NULL,
    sent_received_at TIMESTAMPTZ NOT NULL,
    source TEXT NOT NULL DEFAULT 'ANDROID_SMS',
    device_message_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(source, device_message_id)
);

CREATE INDEX idx_sms_phone_time ON core.sms_messages(phone_number_id, sent_received_at DESC);
CREATE INDEX idx_sms_order_time ON core.sms_messages(service_order_id, sent_received_at DESC);

-- ============================================================================
-- CORE: IMPORT HISTORYCZNY TELEFONU
-- ============================================================================
CREATE TABLE core.phone_import_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_device TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    created_by UUID REFERENCES core.app_users(id),
    imported_unsaved_numbers INTEGER NOT NULL DEFAULT 0,
    imported_selected_contacts INTEGER NOT NULL DEFAULT 0,
    imported_calls INTEGER NOT NULL DEFAULT 0,
    imported_recordings INTEGER NOT NULL DEFAULT 0,
    notes TEXT
);

CREATE TABLE core.phone_import_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id UUID NOT NULL REFERENCES core.phone_import_batches(id) ON DELETE CASCADE,
    item_type TEXT NOT NULL CHECK (item_type IN ('UNSAVED_NUMBER','SELECTED_CONTACT','CALL','RECORDING')),
    external_id TEXT,
    phone_number_id UUID REFERENCES core.phone_numbers(id) ON DELETE SET NULL,
    client_id UUID REFERENCES core.clients(id) ON DELETE SET NULL,
    imported BOOLEAN NOT NULL DEFAULT FALSE,
    merged BOOLEAN NOT NULL DEFAULT FALSE,
    error_message TEXT,
    raw_payload JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_phone_import_items_batch ON core.phone_import_items(batch_id, item_type);

-- ============================================================================
-- CORE: AUDYT + SYNC
-- ============================================================================
CREATE TABLE core.audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES core.app_users(id) ON DELETE SET NULL,
    entity_type TEXT NOT NULL,
    entity_id UUID,
    action TEXT NOT NULL,
    old_data JSONB,
    new_data JSONB,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_log_entity ON core.audit_log(entity_type, entity_id, created_at DESC);
CREATE INDEX idx_audit_log_created ON core.audit_log(created_at DESC);

CREATE TABLE core.sync_events (
    id BIGSERIAL PRIMARY KEY,
    entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    version BIGINT NOT NULL DEFAULT 1,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_by UUID REFERENCES core.app_users(id),
    payload JSONB
);

CREATE INDEX idx_sync_events_after ON core.sync_events(id);
CREATE INDEX idx_sync_events_entity ON core.sync_events(entity_type, entity_id);

-- ============================================================================
-- ASSIST: INSTALACJE / MONITORING / ALERTY
-- Zachowane i polaczone z tym samym core.clients/core.devices.
-- ============================================================================
CREATE TABLE assist.assist_installations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID REFERENCES core.clients(id) ON DELETE SET NULL,
    device_id UUID REFERENCES core.devices(id) ON DELETE SET NULL,
    installation_token UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    computer_name TEXT,
    os_name TEXT,
    os_version TEXT,
    app_version TEXT,
    last_seen_at TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_assist_installations_client ON assist.assist_installations(client_id);
CREATE INDEX idx_assist_installations_device ON assist.assist_installations(device_id);
CREATE TRIGGER trg_assist_installations_updated_at
BEFORE UPDATE ON assist.assist_installations
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE assist.assist_telemetry_snapshots (
    id BIGSERIAL PRIMARY KEY,
    installation_id UUID NOT NULL REFERENCES assist.assist_installations(id) ON DELETE CASCADE,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    cpu_usage NUMERIC(5,2),
    ram_usage NUMERIC(5,2),
    disk_usage NUMERIC(5,2),
    cpu_temperature_c NUMERIC(6,2),
    gpu_temperature_c NUMERIC(6,2),
    boot_time_seconds INTEGER,
    defender_realtime BOOLEAN,
    defender_browser BOOLEAN,
    uptime_hours INTEGER,
    battery_health_pct NUMERIC(6,2),
    battery_cycle_count INTEGER,
    windows_update_status TEXT,
    disks JSONB,
    temperatures JSONB,
    memory JSONB,
    network JSONB,
    raw_payload JSONB
);

CREATE INDEX idx_assist_telemetry_installation_time
ON assist.assist_telemetry_snapshots(installation_id, collected_at DESC);

CREATE TABLE assist.assist_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    installation_id UUID NOT NULL REFERENCES assist.assist_installations(id) ON DELETE CASCADE,
    severity assist.agent_alert_severity NOT NULL,
    alert_code TEXT,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ,
    acknowledged_at TIMESTAMPTZ,
    acknowledged_by UUID REFERENCES core.app_users(id)
);

CREATE INDEX idx_assist_alerts_open
ON assist.assist_alerts(installation_id, resolved_at, last_seen_at DESC);

-- ============================================================================
-- ASSIST: LICENCJE - zachowany system STANDARD / PRO
-- ============================================================================
CREATE TABLE assist.licenses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_key TEXT NOT NULL UNIQUE,
    tier assist.license_tier NOT NULL DEFAULT 'STANDARD',
    status assist.license_status NOT NULL DEFAULT 'ACTIVE',
    valid_from TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_until TIMESTAMPTZ,
    max_devices INTEGER NOT NULL DEFAULT 1 CHECK (max_devices > 0),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_licenses_updated_at
BEFORE UPDATE ON assist.licenses
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE assist.license_assignments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_id UUID NOT NULL REFERENCES assist.licenses(id) ON DELETE CASCADE,
    client_id UUID REFERENCES core.clients(id) ON DELETE SET NULL,
    installation_id UUID REFERENCES assist.assist_installations(id) ON DELETE CASCADE,
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    UNIQUE(license_id, installation_id)
);

CREATE OR REPLACE FUNCTION assist.generate_license_key()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_key TEXT;
BEGIN
    v_key := upper(encode(gen_random_bytes(16), 'hex'));
    RETURN substr(v_key, 1, 8) || '-' ||
           substr(v_key, 9, 8) || '-' ||
           substr(v_key, 17, 8) || '-' ||
           substr(v_key, 25, 8);
END;
$$;

CREATE OR REPLACE FUNCTION assist.create_license(
    p_tier assist.license_tier DEFAULT 'STANDARD',
    p_days INTEGER DEFAULT 365,
    p_note TEXT DEFAULT NULL
)
RETURNS TABLE (
    license_id UUID,
    license_key TEXT,
    tier assist.license_tier,
    valid_until TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id UUID;
    v_key TEXT;
    v_until TIMESTAMPTZ;
BEGIN
    v_key := assist.generate_license_key();
    v_until := now() + make_interval(days => p_days);

    INSERT INTO assist.licenses (license_key, tier, status, valid_from, valid_until, note)
    VALUES (v_key, p_tier, 'ACTIVE', now(), v_until, p_note)
    RETURNING id INTO v_id;

    RETURN QUERY SELECT v_id, v_key, p_tier, v_until;
END;
$$;

-- Powiadomienia Assist.
CREATE TABLE assist.notification_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT UNIQUE NOT NULL,
    category TEXT,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    severity assist.agent_alert_severity NOT NULL DEFAULT 'INFO',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    show_phone BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_notification_templates_updated_at
BEFORE UPDATE ON assist.notification_templates
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE assist.notification_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    installation_id UUID REFERENCES assist.assist_installations(id) ON DELETE CASCADE,
    template_id UUID REFERENCES assist.notification_templates(id) ON DELETE SET NULL,
    title TEXT,
    message TEXT,
    severity assist.agent_alert_severity,
    sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    status TEXT NOT NULL DEFAULT 'sent',
    read_at TIMESTAMPTZ
);

CREATE INDEX idx_notification_logs_installation
ON assist.notification_logs(installation_id);

-- ============================================================================
-- BREEZE: WARSTWA INTEGRACYJNA
-- Nie zastepuje technicznej bazy Breeze. Laczy wspolnego klienta/urzadzenie
-- Multi-Servis z identyfikatorem endpointu Breeze.
-- ============================================================================
CREATE TABLE breeze.device_links (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID REFERENCES core.clients(id) ON DELETE SET NULL,
    device_id UUID NOT NULL REFERENCES core.devices(id) ON DELETE CASCADE,
    breeze_device_id TEXT NOT NULL UNIQUE,
    breeze_instance TEXT,
    endpoint_name TEXT,
    remote_access_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    last_seen_at TIMESTAMPTZ,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_breeze_device_links_client ON breeze.device_links(client_id);
CREATE INDEX idx_breeze_device_links_device ON breeze.device_links(device_id);
CREATE TRIGGER trg_breeze_device_links_updated_at
BEFORE UPDATE ON breeze.device_links
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE breeze.remote_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_link_id UUID NOT NULL REFERENCES breeze.device_links(id) ON DELETE CASCADE,
    requested_by UUID REFERENCES core.app_users(id) ON DELETE SET NULL,
    external_session_id TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ,
    status TEXT,
    metadata JSONB
);

CREATE INDEX idx_breeze_remote_sessions_device
ON breeze.remote_sessions(device_link_id, started_at DESC);

-- ============================================================================
-- CONFIG: USTAWIENIA GLOBALNE
-- ============================================================================
CREATE TABLE config.app_settings (
    key TEXT PRIMARY KEY,
    value TEXT,
    description TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO config.app_settings (key, value, description) VALUES
('company_name', 'Multi-Servis', 'Nazwa firmy'),
('company_phone', '505012914', 'Numer telefonu serwisu'),
('company_phone_e164', '+48505012914', 'Numer telefonu w formacie E.164'),
('company_address', 'Ku Wiatrakom 18, Bydgoszcz Wyżyny', 'Adres serwisu'),
('company_owner', 'Tomasz Jeliński', 'Wlasciciel i serwisant'),
('opening_hours', '10:00 - 17:00', 'Godziny otwarcia serwisu'),
('default_license_days', '365', 'Domyslna dlugosc licencji w dniach'),
('reception_number_start', '11', 'Pierwszy numer przyjecia kazdego dnia'),
('timezone', 'Europe/Warsaw', 'Strefa czasowa numeracji i raportow')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = now();

INSERT INTO core.app_users (username, display_name, role)
VALUES ('tomasz', 'Tomasz Jeliński', 'OWNER')
ON CONFLICT (username) DO NOTHING;

-- ============================================================================
-- WIDOKI DO APLIKACJI
-- ============================================================================
CREATE VIEW service.v_phone_contact_summary AS
SELECT
    p.id AS phone_number_id,
    p.e164,
    COUNT(DISTINCT c.id) AS call_count,
    MAX(c.started_at) AS last_call_at,
    COUNT(DISTINCT so.id) AS service_order_count,
    MAX(so.received_at) AS last_service_order_at,
    MAX(CASE WHEN rr.status = 'VERIFIED' THEN rr.discount_percent ELSE NULL END) AS google_discount_percent
FROM core.phone_numbers p
LEFT JOIN core.calls c ON c.phone_number_id = p.id
LEFT JOIN service.service_orders so
    ON so.primary_phone_id = p.id OR so.secondary_phone_id = p.id
LEFT JOIN service.review_rewards rr ON rr.phone_number_id = p.id
GROUP BY p.id, p.e164;

CREATE VIEW core.v_active_caller_notes AS
SELECT
    cn.id,
    cn.phone_number_id,
    cn.client_id,
    cn.note_text,
    cn.visible_to_reception,
    cn.created_at,
    cn.updated_at
FROM core.caller_notes cn
WHERE cn.is_active = TRUE;

CREATE VIEW service.v_service_order_summary AS
SELECT
    so.id,
    so.reception_number,
    so.order_number,
    so.status,
    so.received_at,
    so.ready_at,
    so.client_notified_at,
    so.completed_at,
    so.released_at,
    p1.e164 AS phone_e164,
    p2.e164 AS second_phone_e164,
    c.display_name,
    c.first_name,
    c.last_name,
    c.company_name,
    d.device_type,
    d.manufacturer,
    d.model,
    d.serial_number,
    so.estimated_cost,
    so.final_cost,
    so.currency,
    (
        SELECT COUNT(*)
        FROM service.service_order_media som
        WHERE som.service_order_id = so.id
          AND som.deleted_at IS NULL
    ) AS media_count
FROM service.service_orders so
JOIN core.phone_numbers p1 ON p1.id = so.primary_phone_id
LEFT JOIN core.phone_numbers p2 ON p2.id = so.secondary_phone_id
LEFT JOIN core.clients c ON c.id = so.client_id
LEFT JOIN core.devices d ON d.id = so.device_id;

-- Raport miesieczny wlasciciela.
CREATE VIEW service.v_owner_monthly_report AS
SELECT
    date_trunc('month', so.received_at AT TIME ZONE 'Europe/Warsaw')::DATE AS month,
    COUNT(*) FILTER (WHERE so.status <> 'CANCELLED') AS orders_count,
    SUM(COALESCE(ofi.service_amount, 0)) AS service_total,
    SUM(COALESCE(ofi.material_cost, 0)) AS material_total,
    SUM(COALESCE(ofi.donor_material_value, 0)) AS donor_material_total,
    SUM(COALESCE(ofi.service_amount, 0) - COALESCE(ofi.material_cost, 0)) AS actual_profit,
    SUM(COALESCE(ofi.service_amount, 0) - COALESCE(ofi.material_cost, 0) - COALESCE(ofi.donor_material_value, 0)) AS economic_profit
FROM service.service_orders so
LEFT JOIN service.owner_finances ofi ON ofi.service_order_id = so.id
GROUP BY 1
ORDER BY 1 DESC;

CREATE VIEW service.v_owner_quarterly_report AS
SELECT
    date_trunc('quarter', so.received_at AT TIME ZONE 'Europe/Warsaw')::DATE AS quarter,
    COUNT(*) FILTER (WHERE so.status <> 'CANCELLED') AS orders_count,
    SUM(COALESCE(ofi.service_amount, 0)) AS service_total,
    SUM(COALESCE(ofi.material_cost, 0)) AS material_total,
    SUM(COALESCE(ofi.donor_material_value, 0)) AS donor_material_total,
    SUM(COALESCE(ofi.service_amount, 0) - COALESCE(ofi.material_cost, 0)) AS actual_profit,
    SUM(COALESCE(ofi.service_amount, 0) - COALESCE(ofi.material_cost, 0) - COALESCE(ofi.donor_material_value, 0)) AS economic_profit
FROM service.service_orders so
LEFT JOIN service.owner_finances ofi ON ofi.service_order_id = so.id
GROUP BY 1
ORDER BY 1 DESC;

CREATE VIEW service.v_owner_yearly_report AS
SELECT
    EXTRACT(YEAR FROM so.received_at AT TIME ZONE 'Europe/Warsaw')::INTEGER AS year,
    COUNT(*) FILTER (WHERE so.status <> 'CANCELLED') AS orders_count,
    SUM(COALESCE(ofi.service_amount, 0)) AS service_total,
    SUM(COALESCE(ofi.material_cost, 0)) AS material_total,
    SUM(COALESCE(ofi.donor_material_value, 0)) AS donor_material_total,
    SUM(COALESCE(ofi.service_amount, 0) - COALESCE(ofi.material_cost, 0)) AS actual_profit,
    SUM(COALESCE(ofi.service_amount, 0) - COALESCE(ofi.material_cost, 0) - COALESCE(ofi.donor_material_value, 0)) AS economic_profit
FROM service.service_orders so
LEFT JOIN service.owner_finances ofi ON ofi.service_order_id = so.id
GROUP BY 1
ORDER BY 1 DESC;

-- ============================================================================
-- PUBLIC: WIDOKI ZGODNOSCI Z V1.1
-- Pozwalaja staremu kodowi dalej odpytywac np. public.clients/public.licenses.
-- Proste widoki SELECT * sa automatycznie aktualizowalne przez PostgreSQL.
-- ============================================================================
DROP VIEW IF EXISTS public.v_phone_contact_summary CASCADE;
DROP VIEW IF EXISTS public.v_active_caller_notes CASCADE;
DROP VIEW IF EXISTS public.v_service_order_summary CASCADE;

DROP VIEW IF EXISTS public.app_users CASCADE;
DROP VIEW IF EXISTS public.phone_numbers CASCADE;
DROP VIEW IF EXISTS public.clients CASCADE;
DROP VIEW IF EXISTS public.client_phones CASCADE;
DROP VIEW IF EXISTS public.phone_archive_rules CASCADE;
DROP VIEW IF EXISTS public.caller_notes CASCADE;
DROP VIEW IF EXISTS public.devices CASCADE;
DROP VIEW IF EXISTS public.storage_objects CASCADE;
DROP VIEW IF EXISTS public.service_orders CASCADE;
DROP VIEW IF EXISTS public.service_order_status_history CASCADE;
DROP VIEW IF EXISTS public.service_order_media CASCADE;
DROP VIEW IF EXISTS public.ocr_runs CASCADE;
DROP VIEW IF EXISTS public.device_data_corrections CASCADE;
DROP VIEW IF EXISTS public.calls CASCADE;
DROP VIEW IF EXISTS public.call_recordings CASCADE;
DROP VIEW IF EXISTS public.call_transcripts CASCADE;
DROP VIEW IF EXISTS public.service_order_cost_items CASCADE;
DROP VIEW IF EXISTS public.customer_approvals CASCADE;
DROP VIEW IF EXISTS public.payments CASCADE;
DROP VIEW IF EXISTS public.review_rewards CASCADE;
DROP VIEW IF EXISTS public.service_order_discounts CASCADE;
DROP VIEW IF EXISTS public.audit_log CASCADE;
DROP VIEW IF EXISTS public.sync_events CASCADE;
DROP VIEW IF EXISTS public.assist_installations CASCADE;
DROP VIEW IF EXISTS public.assist_telemetry_snapshots CASCADE;
DROP VIEW IF EXISTS public.assist_alerts CASCADE;
DROP VIEW IF EXISTS public.licenses CASCADE;
DROP VIEW IF EXISTS public.license_assignments CASCADE;
DROP VIEW IF EXISTS public.notification_templates CASCADE;
DROP VIEW IF EXISTS public.notification_logs CASCADE;
DROP VIEW IF EXISTS public.app_settings CASCADE;

CREATE VIEW public.app_users AS SELECT * FROM core.app_users;
CREATE VIEW public.phone_numbers AS
SELECT id, e164, display_number, first_seen_at, last_seen_at, source, created_at, updated_at
FROM core.phone_numbers;
CREATE VIEW public.clients AS
SELECT id, first_name, last_name, company_name, email, address, notes, google_review, is_active,
       created_at, updated_at, archived_at, created_by, updated_by
FROM core.clients;
CREATE VIEW public.client_phones AS SELECT * FROM core.client_phones;
CREATE VIEW public.phone_archive_rules AS SELECT * FROM core.phone_archive_rules;
CREATE VIEW public.caller_notes AS SELECT * FROM core.caller_notes;
CREATE VIEW public.devices AS
SELECT id, client_id, device_type, manufacturer, model, serial_number, serial_normalized, hostname,
       os, os_version, description, tactical_agent_id, rustdesk_id, last_seen, is_online, notes,
       created_at, updated_at, archived_at, created_by, updated_by
FROM core.devices;
CREATE VIEW public.storage_objects AS SELECT * FROM core.storage_objects;
CREATE VIEW public.service_orders AS SELECT * FROM service.service_orders;
CREATE VIEW public.service_order_status_history AS SELECT * FROM service.service_order_status_history;
CREATE VIEW public.service_order_media AS SELECT * FROM service.service_order_media;
CREATE VIEW public.ocr_runs AS SELECT * FROM service.ocr_runs;
CREATE VIEW public.device_data_corrections AS SELECT * FROM service.device_data_corrections;
CREATE VIEW public.calls AS SELECT * FROM core.calls;
CREATE VIEW public.call_recordings AS SELECT * FROM core.call_recordings;
CREATE VIEW public.call_transcripts AS SELECT * FROM core.call_transcripts;
CREATE VIEW public.service_order_cost_items AS SELECT * FROM service.service_order_cost_items;
CREATE VIEW public.customer_approvals AS SELECT * FROM service.customer_approvals;
CREATE VIEW public.payments AS SELECT * FROM service.payments;
CREATE VIEW public.review_rewards AS SELECT * FROM service.review_rewards;
CREATE VIEW public.service_order_discounts AS SELECT * FROM service.service_order_discounts;
CREATE VIEW public.audit_log AS SELECT * FROM core.audit_log;
CREATE VIEW public.sync_events AS SELECT * FROM core.sync_events;
CREATE VIEW public.assist_installations AS SELECT * FROM assist.assist_installations;
CREATE VIEW public.assist_telemetry_snapshots AS SELECT * FROM assist.assist_telemetry_snapshots;
CREATE VIEW public.assist_alerts AS SELECT * FROM assist.assist_alerts;
CREATE VIEW public.licenses AS SELECT * FROM assist.licenses;
CREATE VIEW public.license_assignments AS SELECT * FROM assist.license_assignments;
CREATE VIEW public.notification_templates AS SELECT * FROM assist.notification_templates;
CREATE VIEW public.notification_logs AS SELECT * FROM assist.notification_logs;
CREATE VIEW public.app_settings AS SELECT * FROM config.app_settings;

CREATE VIEW public.v_phone_contact_summary AS SELECT * FROM service.v_phone_contact_summary;
CREATE VIEW public.v_active_caller_notes AS SELECT * FROM core.v_active_caller_notes;
CREATE VIEW public.v_service_order_summary AS SELECT * FROM service.v_service_order_summary;

-- Wrappery funkcji zgodnosci z v1.1.
CREATE OR REPLACE FUNCTION public.normalize_phone(p_input TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE
AS $$ SELECT core.normalize_phone(p_input); $$;

CREATE OR REPLACE FUNCTION public.parse_call_recording_filename(p_filename TEXT)
RETURNS JSONB LANGUAGE sql IMMUTABLE
AS $$ SELECT core.parse_call_recording_filename(p_filename); $$;

CREATE OR REPLACE FUNCTION public.generate_license_key()
RETURNS TEXT LANGUAGE sql
AS $$ SELECT assist.generate_license_key(); $$;

CREATE OR REPLACE FUNCTION public.create_license(
    p_tier TEXT DEFAULT 'STANDARD',
    p_days INTEGER DEFAULT 365,
    p_note TEXT DEFAULT NULL
)
RETURNS TABLE (
    license_id UUID,
    license_key TEXT,
    tier TEXT,
    valid_until TIMESTAMPTZ
)
LANGUAGE sql
AS $$
    SELECT l.license_id, l.license_key, l.tier::TEXT, l.valid_until
    FROM assist.create_license(p_tier::assist.license_tier, p_days, p_note) l;
$$;

-- ============================================================================
-- KOMENTARZE / ZASADY BEZPIECZENSTWA
-- ============================================================================
COMMENT ON TABLE service.owner_finances IS
'Prywatne finanse wlasciciela. API dla kont RECEPTION/TECHNICIAN nie moze zwracac tej tabeli.';

COMMENT ON TABLE service.service_orders IS
'Jedna sprawa od przyjecia do zakonczenia. Numer przyjecia jest centralny i nigdy nie jest ponownie uzywany.';

COMMENT ON COLUMN service.service_orders.client_notified_at IS
'Data/godzina poinformowania klienta o gotowosci odbioru; wazna dla reguly nieodebranego sprzetu.';

COMMENT ON TABLE breeze.device_links IS
'Powiazanie wspolnego client_id/device_id z technicznym identyfikatorem Breeze.';

COMMIT;

-- ============================================================================
-- SZYBKIE TESTY PO WDROZENIU (uruchamiaj osobno, nie sa czescia transakcji):
--
-- SELECT service.next_reception_number(now());
-- -- UWAGA: ten test zuzywa numer. W produkcji testuj INSERT w transakcji i ROLLBACK.
--
-- SELECT assist.generate_license_key();
-- SELECT core.normalize_phone('505 123 456');
-- SELECT core.phone_match_key('+48 505 123 456');
-- ============================================================================
