-- ============================================================================
-- Multi-Servis - UNIFIED PostgreSQL Schema
-- Wersja: 1.1
-- Czyści starą strukturę i stawia wszystko od zera
-- ============================================================================

BEGIN;

-- Wyczyść starą strukturę (stare tabele INTEGER kolidowały z UUID)
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO CURRENT_USER;
GRANT ALL ON SCHEMA public TO public;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================================
-- ENUMY
-- ============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'app_role') THEN
        CREATE TYPE app_role AS ENUM ('OWNER', 'ADMIN', 'RECEPTION', 'TECHNICIAN', 'READONLY');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'order_status') THEN
        CREATE TYPE order_status AS ENUM (
            'DRAFT','RECEIVED','DIAGNOSIS','WAITING_FOR_CUSTOMER',
            'WAITING_FOR_PARTS','APPROVED','IN_REPAIR','READY',
            'RELEASED','CANCELLED','NOT_REPAIRABLE','ARCHIVED'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'media_kind') THEN
        CREATE TYPE media_kind AS ENUM (
            'DEVICE_LABEL','INTAKE_PHOTO','REPAIR_PHOTO',
            'RELEASE_PHOTO','CALL_RECORDING','DOCUMENT','OTHER'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'call_direction') THEN
        CREATE TYPE call_direction AS ENUM ('INCOMING','OUTGOING','UNKNOWN');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'archive_rule_type') THEN
        CREATE TYPE archive_rule_type AS ENUM ('ARCHIVE_ALWAYS','DO_NOT_ARCHIVE');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'cost_item_type') THEN
        CREATE TYPE cost_item_type AS ENUM ('LABOR','PART','DIAGNOSIS','SHIPPING','DISCOUNT','OTHER');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_method') THEN
        CREATE TYPE payment_method AS ENUM ('CASH','CARD','TRANSFER','BLIK','OTHER');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'review_status') THEN
        CREATE TYPE review_status AS ENUM ('UNCONFIRMED','CONFIRMED','REVOKED');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'license_tier') THEN
        CREATE TYPE license_tier AS ENUM ('STANDARD','PRO');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'license_status') THEN
        CREATE TYPE license_status AS ENUM ('ACTIVE','EXPIRED','REVOKED','PENDING');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'agent_alert_severity') THEN
        CREATE TYPE agent_alert_severity AS ENUM ('INFO','WARNING','CRITICAL');
    END IF;
END $$;

-- ============================================================================
-- FUNKCJE POMOCNICZE
-- ============================================================================
CREATE OR REPLACE FUNCTION normalize_phone(p_input TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v TEXT;
BEGIN
    IF p_input IS NULL THEN RETURN NULL; END IF;

    v := regexp_replace(trim(p_input), '[\s\-\(\)]', '', 'g');

    IF v = '' THEN RETURN NULL; END IF;

    IF left(v, 2) = '00' THEN
        v := '+' || substr(v, 3);
    ELSIF left(v, 1) <> '+' THEN
        v := '+48' || v;
    END IF;

    IF v !~ '^\+[0-9]{7,15}$' THEN
        RAISE EXCEPTION 'Invalid phone number: %', p_input;
    END IF;

    RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION parse_call_recording_filename(p_filename TEXT)
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

    v_match := regexp_match(
        v_name,
        '^(\+[0-9]{7,15})-([0-9]{10})$'
    );

    IF v_match IS NULL THEN
        RETURN jsonb_build_object(
            'valid', false,
            'filename', p_filename
        );
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

-- Generator kluczy licencyjnych
-- Przykład: SELECT generate_license_key();
CREATE OR REPLACE FUNCTION generate_license_key()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_key TEXT;
BEGIN
    v_key := upper(encode(gen_random_bytes(16), 'hex'));
    v_key := substr(v_key, 1, 8) || '-' ||
             substr(v_key, 9, 8) || '-' ||
             substr(v_key, 17, 8) || '-' ||
             substr(v_key, 25, 8);
    RETURN v_key;
END;
$$;

-- Tworzenie licencji (STANDARD lub PRO)
-- Przykład: SELECT * FROM create_license('PRO', 365, 'Klient VIP');
CREATE OR REPLACE FUNCTION create_license(
    p_tier license_tier DEFAULT 'STANDARD',
    p_days INTEGER DEFAULT 365,
    p_note TEXT DEFAULT NULL
)
RETURNS TABLE (
    license_id UUID,
    license_key TEXT,
    tier license_tier,
    valid_until TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id UUID;
    v_key TEXT;
    v_until TIMESTAMPTZ;
BEGIN
    v_key := generate_license_key();
    v_until := now() + (p_days || ' days')::INTERVAL;

    INSERT INTO licenses (license_key, tier, status, valid_from, valid_until, note)
    VALUES (v_key, p_tier, 'ACTIVE', now(), v_until, p_note)
    RETURNING id INTO v_id;

    RETURN QUERY
    SELECT v_id, v_key, p_tier, v_until;
END;
$$;

-- ============================================================================
-- UŻYTKOWNICY SYSTEMU (OWNER / RECEPTION / TECHNICIAN)
-- ============================================================================
CREATE TABLE IF NOT EXISTS app_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    email TEXT,
    role app_role NOT NULL DEFAULT 'RECEPTION',
    password_hash TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at TIMESTAMPTZ
);

CREATE TRIGGER trg_app_users_updated_at
BEFORE UPDATE ON app_users
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- TELEFONY (centralne, niezależne od klienta)
-- ============================================================================
CREATE TABLE IF NOT EXISTS phone_numbers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    e164 TEXT NOT NULL UNIQUE,
    display_number TEXT,
    first_seen_at TIMESTAMPTZ,
    last_seen_at TIMESTAMPTZ,
    source TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (e164 ~ '^\+[0-9]{7,15}$')
);

CREATE TRIGGER trg_phone_numbers_updated_at
BEFORE UPDATE ON phone_numbers
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- KLIENCI
-- ============================================================================
CREATE TABLE IF NOT EXISTS clients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name TEXT,
    last_name TEXT,
    company_name TEXT,
    email TEXT,
    address TEXT,
    notes TEXT,
    google_review BOOLEAN DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at TIMESTAMPTZ,
    created_by UUID REFERENCES app_users(id),
    updated_by UUID REFERENCES app_users(id)
);

CREATE TRIGGER trg_clients_updated_at
BEFORE UPDATE ON clients
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS client_phones (
    client_id UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    phone_number_id UUID NOT NULL REFERENCES phone_numbers(id) ON DELETE RESTRICT,
    label TEXT,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (client_id, phone_number_id)
);

CREATE INDEX IF NOT EXISTS idx_client_phones_phone
ON client_phones(phone_number_id);

-- ============================================================================
-- NOTATKI PRZY NUMERACH + REGUŁY ARCHIWIZACJI
-- ============================================================================
CREATE TABLE IF NOT EXISTS phone_archive_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_number_id UUID NOT NULL REFERENCES phone_numbers(id) ON DELETE CASCADE,
    rule_type archive_rule_type NOT NULL,
    note TEXT,
    created_by UUID REFERENCES app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (phone_number_id, rule_type)
);

CREATE TRIGGER trg_phone_archive_rules_updated_at
BEFORE UPDATE ON phone_archive_rules
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS caller_notes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_number_id UUID NOT NULL REFERENCES phone_numbers(id) ON DELETE CASCADE,
    client_id UUID REFERENCES clients(id) ON DELETE SET NULL,
    note_text TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    visible_to_reception BOOLEAN NOT NULL DEFAULT TRUE,
    created_by UUID REFERENCES app_users(id),
    updated_by UUID REFERENCES app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_caller_notes_phone_active
ON caller_notes(phone_number_id, is_active);

CREATE TRIGGER trg_caller_notes_updated_at
BEFORE UPDATE ON caller_notes
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- URZĄDZENIA
-- ============================================================================
CREATE TABLE IF NOT EXISTS devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID REFERENCES clients(id) ON DELETE SET NULL,
    device_type TEXT,
    manufacturer TEXT,
    model TEXT,
    serial_number TEXT,
    serial_normalized TEXT,
    hostname TEXT,
    os TEXT,
    os_version TEXT,
    description TEXT,
    tactical_agent_id TEXT,
    rustdesk_id TEXT,
    last_seen TIMESTAMPTZ,
    is_online BOOLEAN DEFAULT FALSE,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at TIMESTAMPTZ,
    created_by UUID REFERENCES app_users(id),
    updated_by UUID REFERENCES app_users(id)
);

CREATE INDEX IF NOT EXISTS idx_devices_client ON devices(client_id);
CREATE INDEX IF NOT EXISTS idx_devices_serial_normalized ON devices(serial_normalized);
CREATE INDEX IF NOT EXISTS idx_devices_tactical_agent_id ON devices(tactical_agent_id);

CREATE TRIGGER trg_devices_updated_at
BEFORE UPDATE ON devices
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- ZLECENIA SERWISOWE
-- ============================================================================
CREATE TABLE IF NOT EXISTS service_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_number BIGSERIAL UNIQUE,
    client_id UUID REFERENCES clients(id) ON DELETE SET NULL,
    primary_phone_id UUID NOT NULL REFERENCES phone_numbers(id) ON DELETE RESTRICT,
    device_id UUID REFERENCES devices(id) ON DELETE SET NULL,
    status order_status NOT NULL DEFAULT 'RECEIVED',
    intake_description TEXT,
    fault_description TEXT,
    accessories_received TEXT,
    technician_notes TEXT,
    customer_notes TEXT,
    estimated_cost NUMERIC(12,2),
    final_cost NUMERIC(12,2),
    currency CHAR(3) NOT NULL DEFAULT 'PLN',
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    diagnosed_at TIMESTAMPTZ,
    ready_at TIMESTAMPTZ,
    released_at TIMESTAMPTZ,
    received_by UUID REFERENCES app_users(id),
    assigned_to UUID REFERENCES app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_service_orders_phone ON service_orders(primary_phone_id);
CREATE INDEX IF NOT EXISTS idx_service_orders_client ON service_orders(client_id);
CREATE INDEX IF NOT EXISTS idx_service_orders_device ON service_orders(device_id);
CREATE INDEX IF NOT EXISTS idx_service_orders_status ON service_orders(status);
CREATE INDEX IF NOT EXISTS idx_service_orders_received_at ON service_orders(received_at DESC);

CREATE TRIGGER trg_service_orders_updated_at
BEFORE UPDATE ON service_orders
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS service_order_status_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service_orders(id) ON DELETE CASCADE,
    old_status order_status,
    new_status order_status NOT NULL,
    note TEXT,
    changed_by UUID REFERENCES app_users(id),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_status_history_order
ON service_order_status_history(service_order_id, changed_at DESC);

-- ============================================================================
-- PLIKI / MEDIA (zdjęcia, nagrania) - tylko metadane
-- ============================================================================
CREATE TABLE IF NOT EXISTS storage_objects (
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
    created_by UUID REFERENCES app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES app_users(id)
);

CREATE INDEX IF NOT EXISTS idx_storage_objects_sha256 ON storage_objects(sha256);
CREATE INDEX IF NOT EXISTS idx_storage_objects_created ON storage_objects(created_at DESC);

CREATE TABLE IF NOT EXISTS service_order_media (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service_orders(id) ON DELETE CASCADE,
    storage_object_id UUID NOT NULL REFERENCES storage_objects(id) ON DELETE RESTRICT,
    media_kind media_kind NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    caption TEXT,
    is_source_of_truth BOOLEAN NOT NULL DEFAULT FALSE,
    created_by UUID REFERENCES app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES app_users(id),
    UNIQUE(service_order_id, storage_object_id)
);

CREATE INDEX IF NOT EXISTS idx_service_order_media_order
ON service_order_media(service_order_id, media_kind, sort_order);

-- ============================================================================
-- OCR
-- ============================================================================
CREATE TABLE IF NOT EXISTS ocr_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID REFERENCES service_orders(id) ON DELETE CASCADE,
    device_id UUID REFERENCES devices(id) ON DELETE SET NULL,
    source_media_id UUID NOT NULL REFERENCES service_order_media(id) ON DELETE RESTRICT,
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
    created_by UUID REFERENCES app_users(id)
);

CREATE INDEX IF NOT EXISTS idx_ocr_runs_order ON ocr_runs(service_order_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ocr_runs_media ON ocr_runs(source_media_id);

CREATE TABLE IF NOT EXISTS device_data_corrections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    service_order_id UUID REFERENCES service_orders(id) ON DELETE SET NULL,
    field_name TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT,
    reason TEXT,
    corrected_by UUID REFERENCES app_users(id),
    corrected_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_device_data_corrections_device
ON device_data_corrections(device_id, corrected_at DESC);

-- ============================================================================
-- ROZMOWY + NAGRANIA
-- ============================================================================
CREATE TABLE IF NOT EXISTS calls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_number_id UUID NOT NULL REFERENCES phone_numbers(id) ON DELETE RESTRICT,
    client_id UUID REFERENCES clients(id) ON DELETE SET NULL,
    service_order_id UUID REFERENCES service_orders(id) ON DELETE SET NULL,
    direction call_direction NOT NULL DEFAULT 'UNKNOWN',
    started_at TIMESTAMPTZ NOT NULL,
    duration_seconds INTEGER,
    source TEXT NOT NULL DEFAULT 'ANDROID_DIALER',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (duration_seconds IS NULL OR duration_seconds >= 0)
);

CREATE INDEX IF NOT EXISTS idx_calls_phone_started ON calls(phone_number_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_calls_client_started ON calls(client_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_calls_order ON calls(service_order_id, started_at DESC);

CREATE TRIGGER trg_calls_updated_at
BEFORE UPDATE ON calls
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS call_recordings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
    storage_object_id UUID NOT NULL REFERENCES storage_objects(id) ON DELETE RESTRICT,
    original_filename TEXT NOT NULL,
    parsed_phone_e164 TEXT,
    parsed_started_at TIMESTAMPTZ,
    import_source TEXT,
    imported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(storage_object_id)
);

CREATE INDEX IF NOT EXISTS idx_call_recordings_call ON call_recordings(call_id);
CREATE INDEX IF NOT EXISTS idx_call_recordings_filename ON call_recordings(original_filename);

CREATE TABLE IF NOT EXISTS call_transcripts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    call_recording_id UUID NOT NULL REFERENCES call_recordings(id) ON DELETE CASCADE,
    engine_name TEXT,
    engine_version TEXT,
    language_code TEXT DEFAULT 'pl-PL',
    transcript_text TEXT NOT NULL,
    summary_text TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES app_users(id)
);

CREATE INDEX IF NOT EXISTS idx_call_transcripts_recording ON call_transcripts(call_recording_id);

-- ============================================================================
-- KOSZTY / PŁATNOŚCI / ZATWIERDZENIA
-- ============================================================================
CREATE TABLE IF NOT EXISTS service_order_cost_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service_orders(id) ON DELETE CASCADE,
    item_type cost_item_type NOT NULL,
    description TEXT NOT NULL,
    quantity NUMERIC(12,3) NOT NULL DEFAULT 1,
    unit_price NUMERIC(12,2) NOT NULL DEFAULT 0,
    vat_rate NUMERIC(5,2),
    amount NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    created_by UUID REFERENCES app_users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cost_items_order ON service_order_cost_items(service_order_id);

CREATE TRIGGER trg_cost_items_updated_at
BEFORE UPDATE ON service_order_cost_items
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS customer_approvals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service_orders(id) ON DELETE CASCADE,
    approved BOOLEAN NOT NULL,
    approved_amount NUMERIC(12,2),
    approval_channel TEXT,
    note TEXT,
    approved_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    recorded_by UUID REFERENCES app_users(id)
);

CREATE INDEX IF NOT EXISTS idx_customer_approvals_order
ON customer_approvals(service_order_id, approved_at DESC);

CREATE TABLE IF NOT EXISTS payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service_orders(id) ON DELETE CASCADE,
    amount NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    currency CHAR(3) NOT NULL DEFAULT 'PLN',
    method payment_method NOT NULL,
    reference TEXT,
    paid_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    received_by UUID REFERENCES app_users(id),
    note TEXT
);

CREATE INDEX IF NOT EXISTS idx_payments_order ON payments(service_order_id, paid_at DESC);

-- ============================================================================
-- OPINIE GOOGLE + RABATY
-- ============================================================================
CREATE TABLE IF NOT EXISTS review_rewards (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID REFERENCES clients(id) ON DELETE SET NULL,
    phone_number_id UUID NOT NULL REFERENCES phone_numbers(id) ON DELETE CASCADE,
    platform TEXT NOT NULL DEFAULT 'GOOGLE',
    reviewer_display_name TEXT,
    review_reference TEXT,
    status review_status NOT NULL DEFAULT 'UNCONFIRMED',
    discount_percent NUMERIC(5,2) NOT NULL DEFAULT 10.00
        CHECK (discount_percent >= 0 AND discount_percent <= 100),
    verified_at TIMESTAMPTZ,
    verified_by UUID REFERENCES app_users(id),
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_review_rewards_phone ON review_rewards(phone_number_id, status);

CREATE TRIGGER trg_review_rewards_updated_at
BEFORE UPDATE ON review_rewards
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS service_order_discounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_order_id UUID NOT NULL REFERENCES service_orders(id) ON DELETE CASCADE,
    review_reward_id UUID REFERENCES review_rewards(id) ON DELETE SET NULL,
    discount_percent NUMERIC(5,2),
    discount_amount NUMERIC(12,2),
    reason TEXT,
    applied_by UUID REFERENCES app_users(id),
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- AUDYT + SYNC (offline)
-- ============================================================================
CREATE TABLE IF NOT EXISTS audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES app_users(id) ON DELETE SET NULL,
    entity_type TEXT NOT NULL,
    entity_id UUID,
    action TEXT NOT NULL,
    old_data JSONB,
    new_data JSONB,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_entity ON audit_log(entity_type, entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_created ON audit_log(created_at DESC);

CREATE TABLE IF NOT EXISTS sync_events (
    id BIGSERIAL PRIMARY KEY,
    entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    version BIGINT NOT NULL DEFAULT 1,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_by UUID REFERENCES app_users(id),
    payload JSONB
);

CREATE INDEX IF NOT EXISTS idx_sync_events_after ON sync_events(id);
CREATE INDEX IF NOT EXISTS idx_sync_events_entity ON sync_events(entity_type, entity_id);

-- ============================================================================
-- ASSIST / MONITORING / LICENCJE
-- ============================================================================
CREATE TABLE IF NOT EXISTS assist_installations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID REFERENCES clients(id) ON DELETE SET NULL,
    device_id UUID REFERENCES devices(id) ON DELETE SET NULL,
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

CREATE INDEX IF NOT EXISTS idx_assist_installations_client ON assist_installations(client_id);
CREATE INDEX IF NOT EXISTS idx_assist_installations_device ON assist_installations(device_id);

CREATE TRIGGER trg_assist_installations_updated_at
BEFORE UPDATE ON assist_installations
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS assist_telemetry_snapshots (
    id BIGSERIAL PRIMARY KEY,
    installation_id UUID NOT NULL REFERENCES assist_installations(id) ON DELETE CASCADE,
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

CREATE INDEX IF NOT EXISTS idx_assist_telemetry_installation_time
ON assist_telemetry_snapshots(installation_id, collected_at DESC);

CREATE TABLE IF NOT EXISTS assist_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    installation_id UUID NOT NULL REFERENCES assist_installations(id) ON DELETE CASCADE,
    severity agent_alert_severity NOT NULL,
    alert_code TEXT,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ,
    acknowledged_at TIMESTAMPTZ,
    acknowledged_by UUID REFERENCES app_users(id)
);

CREATE INDEX IF NOT EXISTS idx_assist_alerts_open
ON assist_alerts(installation_id, resolved_at, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS licenses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_key TEXT NOT NULL UNIQUE,
    tier license_tier NOT NULL DEFAULT 'STANDARD',
    status license_status NOT NULL DEFAULT 'ACTIVE',
    valid_from TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_until TIMESTAMPTZ,
    max_devices INTEGER NOT NULL DEFAULT 1 CHECK (max_devices > 0),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_licenses_updated_at
BEFORE UPDATE ON licenses
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS license_assignments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_id UUID NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
    client_id UUID REFERENCES clients(id) ON DELETE SET NULL,
    installation_id UUID REFERENCES assist_installations(id) ON DELETE CASCADE,
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    UNIQUE(license_id, installation_id)
);

CREATE TABLE IF NOT EXISTS notification_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT UNIQUE NOT NULL,
    category TEXT,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    severity agent_alert_severity NOT NULL DEFAULT 'INFO',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    show_phone BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_notification_templates_updated_at
BEFORE UPDATE ON notification_templates
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS notification_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    installation_id UUID REFERENCES assist_installations(id) ON DELETE CASCADE,
    template_id UUID REFERENCES notification_templates(id) ON DELETE SET NULL,
    title TEXT,
    message TEXT,
    severity agent_alert_severity,
    sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    status TEXT NOT NULL DEFAULT 'sent',
    read_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_notification_logs_installation
ON notification_logs(installation_id);

-- ============================================================================
-- USTAWIENIA GLOBALNE
-- ============================================================================
CREATE TABLE IF NOT EXISTS app_settings (
    key TEXT PRIMARY KEY,
    value TEXT,
    description TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO app_settings (key, value, description) VALUES
('company_name', 'Multiserwis', 'Nazwa firmy'),
('company_phone', '505012914', 'Numer telefonu serwisu'),
('company_phone_e164', '+48505012914', 'Numer telefonu w formacie E.164'),
('company_address', 'Ku Wiatrakom 18, Bydgoszcz Wyżyny', 'Adres serwisu'),
('company_owner', 'Tomasz Jeliński', 'Właściciel i serwisant'),
('opening_hours', '10:00 - 17:00', 'Godziny otwarcia serwisu'),
('default_license_days', '365', 'Domyślna długość licencji w dniach')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = now();

-- Domyślny użytkownik OWNER
INSERT INTO app_users (username, display_name, role)
VALUES ('tomasz', 'Tomasz Jeliński', 'OWNER')
ON CONFLICT (username) DO NOTHING;

-- ============================================================================
-- WIDOKI POMOCNICZE
-- ============================================================================
CREATE OR REPLACE VIEW v_phone_contact_summary AS
SELECT
    p.id AS phone_number_id,
    p.e164,
    COUNT(DISTINCT c.id) AS call_count,
    MAX(c.started_at) AS last_call_at,
    COUNT(DISTINCT so.id) AS service_order_count,
    MAX(so.received_at) AS last_service_order_at,
    MAX(CASE WHEN rr.status = 'CONFIRMED' THEN rr.discount_percent ELSE NULL END) AS google_discount_percent
FROM phone_numbers p
LEFT JOIN calls c ON c.phone_number_id = p.id
LEFT JOIN service_orders so ON so.primary_phone_id = p.id
LEFT JOIN review_rewards rr ON rr.phone_number_id = p.id
GROUP BY p.id, p.e164;

CREATE OR REPLACE VIEW v_active_caller_notes AS
SELECT
    cn.id,
    cn.phone_number_id,
    cn.client_id,
    cn.note_text,
    cn.visible_to_reception,
    cn.created_at,
    cn.updated_at
FROM caller_notes cn
WHERE cn.is_active = TRUE;

CREATE OR REPLACE VIEW v_service_order_summary AS
SELECT
    so.id,
    so.order_number,
    so.status,
    so.received_at,
    so.ready_at,
    so.released_at,
    p.e164 AS phone_e164,
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
        FROM service_order_media som
        WHERE som.service_order_id = so.id
          AND som.deleted_at IS NULL
    ) AS media_count
FROM service_orders so
JOIN phone_numbers p ON p.id = so.primary_phone_id
LEFT JOIN clients c ON c.id = so.client_id
LEFT JOIN devices d ON d.id = so.device_id;

COMMIT;
