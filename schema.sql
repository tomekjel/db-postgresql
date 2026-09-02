-- ========================================
-- MULTISERWIS - FINAL DATABASE SCHEMA
-- Version: 1.0
-- ========================================

-- Rozszerzenia
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ========================================
-- 1. KLIENCI
-- ========================================
CREATE TABLE clients (
    id              SERIAL PRIMARY KEY,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100),
    phone           VARCHAR(30),
    email           VARCHAR(150),
    company_name    VARCHAR(150),
    address         TEXT,
    notes           TEXT,
    google_review   BOOLEAN DEFAULT FALSE,
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ========================================
-- 2. URZĄDZENIA
-- ========================================
CREATE TABLE devices (
    id                  SERIAL PRIMARY KEY,
    client_id           INTEGER REFERENCES clients(id) ON DELETE SET NULL,
    device_name         VARCHAR(150),
    hostname            VARCHAR(150),
    serial_number       VARCHAR(100),
    os                  VARCHAR(100),
    os_version          VARCHAR(50),
    manufacturer        VARCHAR(100),
    model               VARCHAR(100),
    tactical_agent_id   VARCHAR(100),
    rustdesk_id         VARCHAR(50),
    last_seen           TIMESTAMPTZ,
    is_online           BOOLEAN DEFAULT FALSE,
    notes               TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_devices_client_id ON devices(client_id);
CREATE INDEX idx_devices_tactical_agent_id ON devices(tactical_agent_id);

-- ========================================
-- 3. LICENCJE
-- ========================================
CREATE TABLE licenses (
    id                  SERIAL PRIMARY KEY,
    device_id           INTEGER REFERENCES devices(id) ON DELETE CASCADE,
    license_key         VARCHAR(64) UNIQUE NOT NULL,
    plan                VARCHAR(20) NOT NULL CHECK (plan IN ('standard', 'pro')),
    status              VARCHAR(20) NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active', 'expired', 'revoked', 'pending')),
    activated_at        TIMESTAMPTZ,
    expires_at          TIMESTAMPTZ,
    last_checked_at     TIMESTAMPTZ,
    max_devices         INTEGER DEFAULT 1,
    notes               TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_licenses_license_key ON licenses(license_key);
CREATE INDEX idx_licenses_device_id ON licenses(device_id);
CREATE INDEX idx_licenses_status ON licenses(status);

-- ========================================
-- 4. HISTORIA SERWISOWA
-- ========================================
CREATE TABLE service_history (
    id                  SERIAL PRIMARY KEY,
    device_id           INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    service_date        DATE NOT NULL,
    service_type        VARCHAR(50),
    description         TEXT NOT NULL,
    parts_used          TEXT,
    cost                DECIMAL(10,2),
    performed_by        VARCHAR(100),
    next_service_date   DATE,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_service_history_device_id ON service_history(device_id);

-- ========================================
-- 5. SZABLONY POWIADOMIEŃ
-- ========================================
CREATE TABLE notification_templates (
    id                  SERIAL PRIMARY KEY,
    code                VARCHAR(50) UNIQUE NOT NULL,
    category            VARCHAR(50),
    title               VARCHAR(200) NOT NULL,
    message             TEXT NOT NULL,
    severity            VARCHAR(20) DEFAULT 'info'
                            CHECK (severity IN ('info', 'warning', 'critical')),
    is_active           BOOLEAN DEFAULT TRUE,
    show_phone          BOOLEAN DEFAULT TRUE,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- ========================================
-- 6. LOGI POWIADOMIEŃ
-- ========================================
CREATE TABLE notification_logs (
    id                  SERIAL PRIMARY KEY,
    device_id           INTEGER REFERENCES devices(id) ON DELETE CASCADE,
    template_id         INTEGER REFERENCES notification_templates(id) ON DELETE SET NULL,
    title               VARCHAR(200),
    message             TEXT,
    severity            VARCHAR(20),
    sent_at             TIMESTAMPTZ DEFAULT NOW(),
    status              VARCHAR(30) DEFAULT 'sent'
                            CHECK (status IN ('sent', 'failed', 'read')),
    read_at             TIMESTAMPTZ
);

CREATE INDEX idx_notification_logs_device_id ON notification_logs(device_id);

-- ========================================
-- 7. STATYSTYKI URZĄDZENIA (snapshoty)
-- ========================================
CREATE TABLE device_stats (
    id                  SERIAL PRIMARY KEY,
    device_id           INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    recorded_at         TIMESTAMPTZ DEFAULT NOW(),

    cpu_usage           DECIMAL(5,2),
    ram_usage           DECIMAL(5,2),
    disk_usage          DECIMAL(5,2),

    cpu_temp            DECIMAL(5,1),
    gpu_temp            DECIMAL(5,1),

    boot_time_seconds   INTEGER,

    defender_realtime   BOOLEAN,
    defender_browser    BOOLEAN,

    uptime_hours        INTEGER,
    notes               TEXT
);

CREATE INDEX idx_device_stats_device_id ON device_stats(device_id);
CREATE INDEX idx_device_stats_recorded_at ON device_stats(recorded_at);

-- ========================================
-- 8. ALERTY / ANOMALIE
-- ========================================
CREATE TABLE device_alerts (
    id                  SERIAL PRIMARY KEY,
    device_id           INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    alert_type          VARCHAR(50) NOT NULL,
    severity            VARCHAR(20) DEFAULT 'warning',
    message             TEXT,
    is_resolved         BOOLEAN DEFAULT FALSE,
    resolved_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_device_alerts_device_id ON device_alerts(device_id);
CREATE INDEX idx_device_alerts_is_resolved ON device_alerts(is_resolved);

-- ========================================
-- 9. USTAWIENIA GLOBALNE
-- ========================================
CREATE TABLE app_settings (
    key                 VARCHAR(100) PRIMARY KEY,
    value               TEXT,
    description         TEXT,
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO app_settings (key, value, description) VALUES
('company_name', 'Multiserwis', 'Nazwa firmy'),
('company_phone', '', 'Numer telefonu wyświetlany w powiadomieniach'),
('company_address', '', 'Adres serwisu'),
('default_license_days', '365', 'Domyślna długość licencji w dniach');

-- ========================================
-- 10. FUNKCJA AUTOMATYCZNEGO updated_at
-- ========================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_clients_updated_at
    BEFORE UPDATE ON clients
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_devices_updated_at
    BEFORE UPDATE ON devices
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_licenses_updated_at
    BEFORE UPDATE ON licenses
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_notification_templates_updated_at
    BEFORE UPDATE ON notification_templates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
