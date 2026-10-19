-- Multi-Servis: warranty returns under original order ID / QR.
-- REVIEW-ONLY migration for the service.* v2 schema in schema.sql.
-- Do NOT run on production before checking the live schema and adapting
-- /receptions/{id}/warranty-return, /receptions, /finances/report.
-- This file is additive: it does not drop or renumber any order.
BEGIN;

DO $$
BEGIN
  IF to_regclass('service.service_orders') IS NULL
     OR to_regclass('service.owner_finances') IS NULL
     OR to_regclass('service.service_order_status_history') IS NULL THEN
    RAISE EXCEPTION 'Incompatible schema: missing service tables. No changes made.';
  END IF;
END $$;

ALTER TABLE service.service_orders
  ADD COLUMN IF NOT EXISTS current_visit_received_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS is_warranty_repair BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS service.service_order_visits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_order_id UUID NOT NULL
    REFERENCES service.service_orders(id) ON DELETE CASCADE,
  visit_number INTEGER NOT NULL CHECK (visit_number >= 1),
  is_current BOOLEAN NOT NULL DEFAULT TRUE,
  is_warranty_return BOOLEAN NOT NULL DEFAULT FALSE,
  received_at TIMESTAMPTZ NOT NULL,
  ready_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  status service.reception_status NOT NULL,
  service_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (service_amount >= 0),
  material_cost NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (material_cost >= 0),
  donor_material_value NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (donor_material_value >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(service_order_id, visit_number)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_service_order_current_visit
  ON service.service_order_visits(service_order_id) WHERE is_current;
CREATE INDEX IF NOT EXISTS ix_service_order_visits_completed
  ON service.service_order_visits(completed_at)
  WHERE status = 'COMPLETED';

-- Backfill only when the order has no visit yet. Original financial amounts
-- are assigned to the original release, NEVER to a subsequent reopening.
INSERT INTO service.service_order_visits (
  service_order_id, visit_number, is_current, is_warranty_return,
  received_at, ready_at, completed_at, status,
  service_amount, material_cost, donor_material_value
)
SELECT
  so.id, 1, TRUE, FALSE,
  so.received_at, so.ready_at, so.completed_at, so.status,
  COALESCE(f.service_amount, 0),
  COALESCE(f.material_cost, 0),
  COALESCE(f.donor_material_value, 0)
FROM service.service_orders so
LEFT JOIN service.owner_finances f ON f.service_order_id = so.id
WHERE NOT EXISTS (
  SELECT 1 FROM service.service_order_visits v
  WHERE v.service_order_id = so.id
);

UPDATE service.service_orders so
  SET current_visit_received_at = COALESCE(
    (SELECT v.received_at FROM service.service_order_visits v
     WHERE v.service_order_id=so.id AND v.is_current),
    so.received_at
  )
WHERE so.current_visit_received_at IS NULL;

-- New orders created after this migration also need visit number 1.
CREATE OR REPLACE FUNCTION service.track_first_visit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO service.service_order_visits (
    service_order_id, visit_number, received_at, ready_at,
    completed_at, status, is_current, is_warranty_return
  ) VALUES (
    NEW.id, 1, NEW.received_at, NEW.ready_at,
    NEW.completed_at, NEW.status, TRUE, FALSE
  );
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_track_first_visit
  ON service.service_orders;
CREATE TRIGGER trg_track_first_visit
AFTER INSERT ON service.service_orders
FOR EACH ROW EXECUTE FUNCTION service.track_first_visit();

-- Existing reception-finance endpoint still edits owner_finances. Mirror only
-- the CURRENT visit; earlier closed periods are immutable.
CREATE OR REPLACE FUNCTION service.sync_current_visit_finances()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  UPDATE service.service_order_visits
  SET service_amount=NEW.service_amount,
      material_cost=NEW.material_cost,
      donor_material_value=NEW.donor_material_value
  WHERE service_order_id=NEW.service_order_id AND is_current;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_sync_current_visit_finances
  ON service.owner_finances;
CREATE TRIGGER trg_sync_current_visit_finances
AFTER INSERT OR UPDATE OF service_amount,material_cost,donor_material_value
  ON service.owner_finances
FOR EACH ROW EXECUTE FUNCTION service.sync_current_visit_finances();

-- Current visit lifecycle mirrors normal changes: IN_SERVICE -> READY -> COMPLETED.
CREATE OR REPLACE FUNCTION service.sync_current_visit_lifecycle()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  UPDATE service.service_order_visits
  SET status=NEW.status,
      ready_at=NEW.ready_at,
      completed_at=NEW.completed_at
  WHERE service_order_id=NEW.id AND is_current;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_sync_current_visit_lifecycle
  ON service.service_orders;
CREATE TRIGGER trg_sync_current_visit_lifecycle
AFTER UPDATE OF status ON service.service_orders
FOR EACH ROW EXECUTE FUNCTION service.sync_current_visit_lifecycle();

-- Protect previously issued financial periods from accidental legacy
-- status PATCH. Only the atomic return function may reopen a released order.
CREATE OR REPLACE FUNCTION service.block_unsafe_order_reopen()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'COMPLETED'
     AND NEW.status <> 'COMPLETED'
     AND COALESCE(current_setting('multiservis.warranty_reopen',TRUE),'')
         <> 'authorized' THEN
    RAISE EXCEPTION
      'COMPLETED_ORDER_REQUIRES_WARRANTY_RETURN'
      USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_block_unsafe_order_reopen
  ON service.service_orders;
CREATE TRIGGER trg_block_unsafe_order_reopen
BEFORE UPDATE OF status ON service.service_orders
FOR EACH ROW EXECUTE FUNCTION service.block_unsafe_order_reopen();

-- The backend must call this function ONLY after OWNER/STAFF authorization.
-- A single atomic transaction locks the issued order, archives the settled
-- period and financial figures, then creates a separate zero-cost period.
CREATE OR REPLACE FUNCTION service.reopen_warranty_return(
  p_order_id UUID,
  p_actor UUID DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_order service.service_orders%ROWTYPE;
  v_current service.service_order_visits%ROWTYPE;
  v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
  SELECT * INTO v_order
  FROM service.service_orders
  WHERE id = p_order_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0002';
  END IF;
  IF v_order.status <> 'COMPLETED' THEN
    RAISE EXCEPTION 'ONLY_COMPLETED_ORDER_CAN_RETURN'
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_current FROM service.service_order_visits
  WHERE service_order_id=p_order_id AND is_current FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MISSING_CURRENT_VISIT' USING ERRCODE='23514';
  END IF;

  -- Lock and snapshot current finance even if another editor used the
  -- old finances endpoint; do not silently transfer revenue to new period.
  PERFORM 1 FROM service.owner_finances
  WHERE service_order_id=p_order_id FOR UPDATE;

  UPDATE service.service_order_visits v SET
    service_amount=COALESCE(f.service_amount,0),
    material_cost=COALESCE(f.material_cost,0),
    donor_material_value=COALESCE(f.donor_material_value,0),
    completed_at=COALESCE(v.completed_at,v_order.completed_at),
    status='COMPLETED',
    is_current=FALSE
  FROM (SELECT * FROM service.owner_finances
        WHERE service_order_id=p_order_id) f
  WHERE v.id=v_current.id;
  -- If no owner_finances row existed, close that period without changes.
  UPDATE service.service_order_visits SET
    status='COMPLETED',
    completed_at=COALESCE(completed_at,v_order.completed_at),
    is_current=FALSE
  WHERE id=v_current.id;

  INSERT INTO service.service_order_visits
    (service_order_id,visit_number,is_current,is_warranty_return,
     received_at,status)
  VALUES
    (p_order_id,v_current.visit_number+1,TRUE,TRUE,v_now,'IN_SERVICE');

  INSERT INTO service.owner_finances
    (service_order_id,service_amount,material_cost,donor_material_value)
  VALUES(p_order_id,0,0,0)
  ON CONFLICT (service_order_id) DO UPDATE SET
    service_amount=0,material_cost=0,donor_material_value=0;

  PERFORM set_config('multiservis.warranty_reopen','authorized',TRUE);
  UPDATE service.service_orders SET
    status='IN_SERVICE', ready_at=NULL, completed_at=NULL,
    released_at=NULL, client_notified_at=NULL,
    current_visit_received_at=v_now,
    is_warranty_repair=TRUE,
    updated_by=COALESCE(p_actor,updated_by)
  WHERE id=p_order_id;
  PERFORM set_config('multiservis.warranty_reopen','off',TRUE);

  -- Existing trigger writes a status history entry COMPLETED -> IN_SERVICE.
  -- Original received_at, reception_number, id, QR and notes stay intact.
END $$;

-- FINANCIAL SOURCE OF TRUTH: one settled visit = one release-date entry.
-- Android and OWNER reports must use completed_at in this view rather than
-- summing the mutable per-order owner_finances table.
CREATE OR REPLACE VIEW service.v_owner_completed_visit_profit AS
SELECT
  v.id AS visit_id, v.service_order_id, o.reception_number,
  v.visit_number, v.is_warranty_return, v.received_at, v.completed_at,
  v.service_amount, v.material_cost, v.donor_material_value,
  (v.service_amount-v.material_cost)::NUMERIC(12,2) AS actual_profit,
  (v.service_amount-v.material_cost-v.donor_material_value)::NUMERIC(12,2)
    AS economic_profit
FROM service.service_order_visits v
JOIN service.service_orders o ON o.id=v.service_order_id
WHERE v.status='COMPLETED' AND v.completed_at IS NOT NULL;


-- Keep legacy OWNER reports aligned with the same release-date ledger.
-- All amounts from a June issue stay in June, including after an October
-- warranty return; a paid October return is counted separately in October.
CREATE OR REPLACE VIEW service.v_owner_monthly_report AS
SELECT date_trunc(
         'month',completed_at AT TIME ZONE 'Europe/Warsaw'
       )::DATE AS month,
       COUNT(*) AS orders_count,
       SUM(service_amount) AS service_total,
       SUM(material_cost) AS material_total,
       SUM(donor_material_value) AS donor_material_total,
       SUM(actual_profit) AS actual_profit,
       SUM(economic_profit) AS economic_profit
FROM service.v_owner_completed_visit_profit
GROUP BY 1 ORDER BY 1 DESC;

CREATE OR REPLACE VIEW service.v_owner_quarterly_report AS
SELECT date_trunc(
         'quarter',completed_at AT TIME ZONE 'Europe/Warsaw'
       )::DATE AS quarter,
       COUNT(*) AS orders_count,
       SUM(service_amount) AS service_total,
       SUM(material_cost) AS material_total,
       SUM(donor_material_value) AS donor_material_total,
       SUM(actual_profit) AS actual_profit,
       SUM(economic_profit) AS economic_profit
FROM service.v_owner_completed_visit_profit
GROUP BY 1 ORDER BY 1 DESC;

CREATE OR REPLACE VIEW service.v_owner_yearly_report AS
SELECT EXTRACT(
         YEAR FROM completed_at AT TIME ZONE 'Europe/Warsaw'
       )::INTEGER AS year,
       COUNT(*) AS orders_count,
       SUM(service_amount) AS service_total,
       SUM(material_cost) AS material_total,
       SUM(donor_material_value) AS donor_material_total,
       SUM(actual_profit) AS actual_profit,
       SUM(economic_profit) AS economic_profit
FROM service.v_owner_completed_visit_profit
GROUP BY 1 ORDER BY 1 DESC;


COMMIT;
