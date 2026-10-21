

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."MediaCategory" AS ENUM (
    'package',
    'task',
    'accessory',
    'service',
    'big_side',
    'small_side',
    'lid',
    'base',
    'item',
    'vacuum_packing',
    'gas_packing',
    'maint_survey',
    'maint_repack',
    'maint_unpack',
    'maint-temp-1',
    'maint-temp'
);


ALTER TYPE "public"."MediaCategory" OWNER TO "postgres";


CREATE TYPE "public"."maintenance_package_type" AS ENUM (
    'defensor',
    'standard_box'
);


ALTER TYPE "public"."maintenance_package_type" OWNER TO "postgres";


CREATE TYPE "public"."maintenance_task_category" AS ENUM (
    'survey',
    'unpack',
    'repack'
);


ALTER TYPE "public"."maintenance_task_category" OWNER TO "postgres";


CREATE TYPE "public"."maintenance_task_status" AS ENUM (
    'pending',
    'in_progress',
    'completed',
    'skipped'
);


ALTER TYPE "public"."maintenance_task_status" OWNER TO "postgres";


CREATE TYPE "public"."material_type" AS ENUM (
    'Accessories',
    'Securing',
    'Gas Packing',
    'Vacuum Packing',
    'Body',
    'Big Sides',
    'Small Sides',
    'Lid',
    'Base',
    'Additional Wood',
    'Defensor',
    'Heatshrink'
);


ALTER TYPE "public"."material_type" OWNER TO "postgres";


CREATE TYPE "public"."packer_status" AS ENUM (
    'available',
    'busy',
    'break'
);


ALTER TYPE "public"."packer_status" OWNER TO "postgres";


COMMENT ON TYPE "public"."packer_status" IS 'This enum shows the possible states the packer can be in a project';



CREATE TYPE "public"."project_type" AS ENUM (
    'standard',
    'maintenance',
    'survey'
);


ALTER TYPE "public"."project_type" OWNER TO "postgres";


CREATE TYPE "public"."request_action" AS ENUM (
    'approved',
    'rejected'
);


ALTER TYPE "public"."request_action" OWNER TO "postgres";


CREATE TYPE "public"."request_type" AS ENUM (
    'material',
    'material_variant',
    'supplier_pricing',
    'allocation_increase'
);


ALTER TYPE "public"."request_type" OWNER TO "postgres";


CREATE TYPE "public"."securing_side" AS ENUM (
    'big_sides',
    'small_sides',
    'lid',
    'base'
);


ALTER TYPE "public"."securing_side" OWNER TO "postgres";


CREATE TYPE "public"."task_status" AS ENUM (
    'in_progress',
    'paused',
    'completed'
);


ALTER TYPE "public"."task_status" OWNER TO "postgres";


COMMENT ON TYPE "public"."task_status" IS 'this enum contains the status of a task at a given time';



CREATE OR REPLACE FUNCTION "public"."add_order_item_allocation"("p_order_id" "uuid", "p_items_db_id" "uuid", "p_destination_id" "uuid", "p_expected" numeric, "p_is_standard_box" boolean) RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE v_id uuid;
BEGIN
  IF p_expected IS NULL OR p_expected <= 0 THEN RAISE EXCEPTION 'expected_qty must be > 0'; END IF;
  IF p_expected <> floor(p_expected) THEN RAISE EXCEPTION 'expected_qty must be a whole number'; END IF;
  IF p_order_id IS NULL OR p_items_db_id IS NULL OR p_destination_id IS NULL THEN RAISE EXCEPTION 'order, item and destination are required'; END IF;
  INSERT INTO order_item_allocation (order_id, items_db_id, destination_id, expected_qty, packed_qty, is_standard_box)
  VALUES (p_order_id, p_items_db_id, p_destination_id, p_expected, 0, COALESCE(p_is_standard_box,false))
  ON CONFLICT (order_id, items_db_id, destination_id)
  DO UPDATE SET expected_qty = COALESCE(order_item_allocation.expected_qty,0) + EXCLUDED.expected_qty, is_standard_box = EXCLUDED.is_standard_box, updated_at = now()
  RETURNING id INTO v_id;
  UPDATE items_db SET expected_qty = COALESCE(expected_qty,0) + p_expected, updated_at = now() WHERE id = p_items_db_id;
  RETURN v_id;
END; $$;


ALTER FUNCTION "public"."add_order_item_allocation"("p_order_id" "uuid", "p_items_db_id" "uuid", "p_destination_id" "uuid", "p_expected" numeric, "p_is_standard_box" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Set the new team lead (keeps existing leads)
  UPDATE order_team_members
  SET is_team_lead = TRUE
  WHERE order_id = order_uuid
    AND packer_id = packer_uuid;
  
  -- If the packer is not already in the team, add them as a lead
  INSERT INTO order_team_members (order_id, packer_id, is_team_lead)
  VALUES (order_uuid, packer_uuid, TRUE)
  ON CONFLICT (order_id, packer_id) 
  DO UPDATE SET is_team_lead = TRUE;
END;
$$;


ALTER FUNCTION "public"."add_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_force_release_packer"("packer_uuid" "uuid") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  affected_orders UUID[] := ARRAY[]::UUID[];
  memberships_removed INTEGER := 0;
  sessions_closed INTEGER := 0;
  attendance_closed INTEGER := 0;
  assignments_completed INTEGER := 0;
BEGIN
  SELECT COALESCE(array_agg(DISTINCT order_id), ARRAY[]::UUID[])
  INTO affected_orders
  FROM order_team_members
  WHERE packer_id = packer_uuid;

  UPDATE task_assignments
  SET task_status = 'completed'
  WHERE packer_id = packer_uuid
    AND task_status <> 'completed';
  GET DIAGNOSTICS assignments_completed = ROW_COUNT;

  UPDATE attendance_logs
  SET end_time = COALESCE(end_time, now()),
      updated_at = now()
  WHERE packer_id = packer_uuid
    AND end_time IS NULL;
  GET DIAGNOSTICS attendance_closed = ROW_COUNT;

  UPDATE packer_sessions
  SET session_active = FALSE,
      updated_at = now()
  WHERE packer_id = packer_uuid
    AND session_active = TRUE;
  GET DIAGNOSTICS sessions_closed = ROW_COUNT;

  DELETE FROM order_team_members
  WHERE packer_id = packer_uuid;
  GET DIAGNOSTICS memberships_removed = ROW_COUNT;

  IF array_length(affected_orders, 1) IS NOT NULL THEN
    UPDATE orders o
    SET project_lead_id = NULL,
        updated_at = now()
    WHERE o.id = ANY(affected_orders)
      AND o.project_lead_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM order_team_members otm
        WHERE otm.order_id = o.id
          AND otm.packer_id = o.project_lead_id
      );

    UPDATE orders o
    SET production_status = 'pending',
        project_lead_id = NULL,
        updated_at = now()
    WHERE o.id = ANY(affected_orders)
      AND o.production_status <> 'completed'
      AND NOT EXISTS (
        SELECT 1
        FROM order_team_members otm
        WHERE otm.order_id = o.id
      );
  END IF;

  UPDATE profiles
  SET packer_status = 'available',
      current_order_id = NULL,
      updated_at = now()
  WHERE id = packer_uuid;

  RETURN json_build_object(
    'success', true,
    'memberships_removed', memberships_removed,
    'sessions_closed', sessions_closed,
    'attendance_closed', attendance_closed,
    'assignments_completed', assignments_completed,
    'affected_orders', affected_orders
  );
END;
$$;


ALTER FUNCTION "public"."admin_force_release_packer"("packer_uuid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_force_release_packer"("packer_uuid" "uuid") IS 'Admin utility to fully free a packer by clearing memberships, active sessions, open attendance, active task assignments, and resetting profile status.';



CREATE OR REPLACE FUNCTION "public"."apply_order_item_allocations"("p_order_id" "uuid", "p_allocations" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- 1. items_db.expected_qty += (new total for this order) - (old total for this order),
  --    atomically, over the union of items that were or are now in this order.
  WITH new_tot AS (
    SELECT (a->>'items_db_id')::uuid AS items_db_id,
           sum((a->>'expected_qty')::numeric) AS total
    FROM jsonb_array_elements(p_allocations) a
    GROUP BY 1
  ),
  old_tot AS (
    SELECT items_db_id, sum(expected_qty) AS total
    FROM order_item_allocation
    WHERE order_id = p_order_id
    GROUP BY 1
  ),
  deltas AS (
    SELECT coalesce(n.items_db_id, o.items_db_id) AS items_db_id,
           coalesce(n.total, 0) - coalesce(o.total, 0) AS delta
    FROM new_tot n
    FULL OUTER JOIN old_tot o ON o.items_db_id = n.items_db_id
  )
  UPDATE items_db i
  SET expected_qty = coalesce(i.expected_qty, 0) + d.delta,
      updated_at = now()
  FROM deltas d
  WHERE d.items_db_id = i.id AND d.delta <> 0;

  -- 2. drop this order's allocation rows that are no longer in the new payload.
  DELETE FROM order_item_allocation oia
  WHERE oia.order_id = p_order_id
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_allocations) a
      WHERE (a->>'items_db_id')::uuid = oia.items_db_id
        AND (a->>'destination_id')::uuid = oia.destination_id
    );

  -- 3. upsert the new allocations. packed_qty is never touched (preserved on conflict,
  --    defaults to 0 on insert).
  INSERT INTO order_item_allocation
    (order_id, items_db_id, destination_id, expected_qty, packing_type, is_standard_box, category_tag)
  SELECT p_order_id,
         (a->>'items_db_id')::uuid,
         (a->>'destination_id')::uuid,
         (a->>'expected_qty')::numeric,
         a->>'packing_type',
         coalesce((a->>'is_standard_box')::boolean, false),
         a->>'category_tag'
  FROM jsonb_array_elements(p_allocations) a
  ON CONFLICT (order_id, items_db_id, destination_id)
  DO UPDATE SET expected_qty = excluded.expected_qty,
                packing_type = excluded.packing_type,
                is_standard_box = excluded.is_standard_box,
                category_tag = excluded.category_tag,
                updated_at = now();
END;
$$;


ALTER FUNCTION "public"."apply_order_item_allocations"("p_order_id" "uuid", "p_allocations" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_allocation_increase_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text" DEFAULT NULL::"text", "p_granted_delta" numeric DEFAULT NULL::numeric) RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  req public.allocation_increase_requests%ROWTYPE;
  v_alloc_id uuid;
  v_delta numeric;
BEGIN
  SELECT * INTO req FROM allocation_increase_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Allocation increase request % not found', p_request_id; END IF;

  -- Admin may grant a different amount than requested ("edit then approve");
  -- default to the packer's requested delta when no override is supplied.
  v_delta := COALESCE(p_granted_delta, req.requested_delta);
  IF v_delta IS NULL OR v_delta <= 0 THEN
    RAISE EXCEPTION 'Granted delta must be greater than 0 (got %)', v_delta;
  END IF;

  -- Raise (or create) the order's allocation for this item+destination by the granted delta.
  INSERT INTO order_item_allocation (order_id, items_db_id, destination_id, expected_qty)
  VALUES (req.order_id, req.items_db_id, req.destination_id, v_delta)
  ON CONFLICT (order_id, items_db_id, destination_id)
  DO UPDATE SET expected_qty = order_item_allocation.expected_qty + v_delta,
                updated_at = now()
  RETURNING id INTO v_alloc_id;

  -- items_db.expected_qty is the rollup of allocations, so it rises by the same delta.
  UPDATE items_db SET expected_qty = coalesce(expected_qty, 0) + v_delta,
                      updated_at = now()
  WHERE id = req.items_db_id;

  INSERT INTO request_audit_log
    (request_type, action, request_snapshot, requested_by, requested_at,
     reviewed_by, reviewed_at, admin_notes, resulting_id, order_package_context)
  VALUES ('allocation_increase', 'approved',
          jsonb_set(to_jsonb(req), '{granted_delta}', to_jsonb(v_delta)),
          req.requested_by, req.requested_at,
          p_reviewed_by, now(), p_admin_notes, v_alloc_id, req.order_package_context);

  DELETE FROM allocation_increase_requests WHERE id = p_request_id;
  RETURN v_alloc_id;
END;
$$;


ALTER FUNCTION "public"."approve_allocation_increase_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text", "p_granted_delta" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_material_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_req        material_requests%ROWTYPE;
  v_new_id     uuid;
BEGIN
  SELECT * INTO v_req FROM material_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'material_request % not found', p_request_id;
  END IF;

  -- promote to main table
  INSERT INTO materials (name, description, unit_id)
  VALUES (v_req.name, v_req.description, v_req.unit_id)
  RETURNING id INTO v_new_id;

  -- swap pointer: any variant requests waiting on this material request
  UPDATE material_variant_requests
  SET    material_id         = v_new_id,
         material_request_id = NULL
  WHERE  material_request_id = p_request_id;

  -- audit
  INSERT INTO request_audit_log (
    request_type, action, request_snapshot,
    requested_by, requested_at,
    reviewed_by, reviewed_at,
    admin_notes, resulting_id, order_package_context
  ) VALUES (
    'material', 'approved', to_jsonb(v_req),
    v_req.requested_by, v_req.requested_at,
    p_reviewed_by, now(),
    p_admin_notes, v_new_id, v_req.order_package_context
  );

  DELETE FROM material_requests WHERE id = p_request_id;

  RETURN v_new_id;
END;
$$;


ALTER FUNCTION "public"."approve_material_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_material_variant_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_req    material_variant_requests%ROWTYPE;
  v_new_id uuid;
BEGIN
  SELECT * INTO v_req FROM material_variant_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'material_variant_request % not found', p_request_id;
  END IF;

  IF v_req.material_id IS NULL THEN
    RAISE EXCEPTION 'Cannot approve variant request %: parent material request is still pending', p_request_id;
  END IF;

  INSERT INTO material_variants (
    material_id, variant_name, attributes, description,
    unit_id, length, width, thickness, weight_per_unit
  ) VALUES (
    v_req.material_id, v_req.variant_name, v_req.attributes, v_req.description,
    v_req.unit_id, v_req.length, v_req.width, v_req.thickness, v_req.weight_per_unit
  )
  RETURNING id INTO v_new_id;

  -- swap in supplier_pricing_requests
  UPDATE supplier_pricing_requests
  SET    material_variant_id = v_new_id,
         variant_request_id  = NULL
  WHERE  variant_request_id  = p_request_id;

  -- swap in order_package_materials (packer already used the pending variant)
  UPDATE order_package_materials
  SET    material_variant_id = v_new_id,
         variant_request_id  = NULL
  WHERE  variant_request_id  = p_request_id;

  INSERT INTO request_audit_log (
    request_type, action, request_snapshot,
    requested_by, requested_at,
    reviewed_by, reviewed_at,
    admin_notes, resulting_id, order_package_context
  ) VALUES (
    'material_variant', 'approved', to_jsonb(v_req),
    v_req.requested_by, v_req.requested_at,
    p_reviewed_by, now(),
    p_admin_notes, v_new_id, v_req.order_package_context
  );

  DELETE FROM material_variant_requests WHERE id = p_request_id;

  RETURN v_new_id;
END;
$$;


ALTER FUNCTION "public"."approve_material_variant_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_supplier_pricing_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_req    supplier_pricing_requests%ROWTYPE;
  v_new_id uuid;
BEGIN
  SELECT * INTO v_req FROM supplier_pricing_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'supplier_pricing_request % not found', p_request_id;
  END IF;

  IF v_req.material_variant_id IS NULL THEN
    RAISE EXCEPTION 'Cannot approve pricing request %: parent variant request is still pending', p_request_id;
  END IF;

  INSERT INTO supplier_pricing (
    material_variant_id, supplier_id, price,
    price_per_unit, supplier_quantity, suppliers_reference
  ) VALUES (
    v_req.material_variant_id, v_req.supplier_id, v_req.price,
    v_req.price_per_unit, v_req.supplier_quantity, v_req.suppliers_reference
  )
  RETURNING id INTO v_new_id;

  INSERT INTO request_audit_log (
    request_type, action, request_snapshot,
    requested_by, requested_at,
    reviewed_by, reviewed_at,
    admin_notes, resulting_id, order_package_context
  ) VALUES (
    'supplier_pricing', 'approved', to_jsonb(v_req),
    v_req.requested_by, v_req.requested_at,
    p_reviewed_by, now(),
    p_admin_notes, v_new_id, v_req.order_package_context
  );

  DELETE FROM supplier_pricing_requests WHERE id = p_request_id;

  RETURN v_new_id;
END;
$$;


ALTER FUNCTION "public"."approve_supplier_pricing_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_packers_to_order"("order_uuid" "uuid", "packer_ids" "uuid"[]) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ DECLARE current_packer_id UUID; BEGIN IF NOT EXISTS (SELECT 1 FROM public.orders WHERE id = order_uuid) THEN RAISE EXCEPTION 'Order does not exist'; END IF; DELETE FROM public.order_team_members WHERE order_id = order_uuid; FOREACH current_packer_id IN ARRAY packer_ids LOOP INSERT INTO public.order_team_members (order_id, packer_id) VALUES (order_uuid, current_packer_id) ON CONFLICT (order_id, packer_id) DO NOTHING; END LOOP; RETURN TRUE; END; $$;


ALTER FUNCTION "public"."assign_packers_to_order"("order_uuid" "uuid", "packer_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_report_number"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.report_number IS NULL THEN
    NEW.report_number := 'RPT-' || to_char(now(), 'YYYY') || '-' ||
                         lpad(nextval('report_number_seq')::text, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."assign_report_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Remove any existing team leads for this order
  UPDATE order_team_members
  SET is_team_lead = FALSE
  WHERE order_id = order_uuid
    AND is_team_lead = TRUE;

  -- Set the new team lead
  UPDATE order_team_members
  SET is_team_lead = TRUE
  WHERE order_id = order_uuid
    AND packer_id = packer_uuid;
  
  -- If the packer is not already in the team, add them
  INSERT INTO order_team_members (order_id, packer_id, is_team_lead)
  VALUES (order_uuid, packer_uuid, TRUE)
  ON CONFLICT (order_id, packer_id) 
  DO UPDATE SET is_team_lead = TRUE;
END;
$$;


ALTER FUNCTION "public"."assign_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."assign_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") IS 'Assigns a single team lead, removing all other leads (backward compatible). Use add_team_lead for multiple leads.';



CREATE OR REPLACE FUNCTION "public"."can_be_project_lead"("user_uuid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    -- Check if user is a packer and is available/busy but not unavailable
    RETURN EXISTS (
        SELECT 1 FROM public.profiles p
        JOIN public.roles r ON p.role_id = r.id
        WHERE p.id = user_uuid
        AND r.name = 'packer'
        AND p.status = 'active'
        AND (p.packer_status IN ('available', 'busy'))
    );
END;
$$;


ALTER FUNCTION "public"."can_be_project_lead"("user_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_record_attendance"("order_uuid" "uuid", "packer_uuid" "uuid", "shift_period_param" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ DECLARE existing_record RECORD; BEGIN SELECT * FROM attendance_logs INTO existing_record WHERE order_id = order_uuid AND packer_id = packer_uuid AND shift_period = shift_period_param AND log_date = CURRENT_DATE AND status = 'present' AND end_time IS NULL ORDER BY created_at DESC LIMIT 1; IF existing_record.id IS NOT NULL THEN RETURN FALSE; END IF; RETURN TRUE; END; $$;


ALTER FUNCTION "public"."can_record_attendance"("order_uuid" "uuid", "packer_uuid" "uuid", "shift_period_param" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_resume_task"("task_log_id" "uuid") RETURNS json
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$ 
DECLARE 
  result JSON; 
  busy_packers UUID[]; 
  assigned_packers UUID[]; 
  busy_count INTEGER; 
BEGIN 
  -- Get packers assigned to this task
  SELECT array_agg(packer_id) INTO assigned_packers 
  FROM task_assignments 
  WHERE task_id = task_log_id;
  
  -- Get busy packers (those with in_progress assignments on other tasks)
  SELECT array_agg(DISTINCT ta.packer_id) INTO busy_packers 
  FROM task_assignments ta 
  JOIN task_logs tl ON ta.task_id = tl.id 
  WHERE ta.task_status = 'in_progress' 
    AND tl.end_time IS NULL 
    AND ta.task_id != task_log_id 
    AND ta.packer_id = ANY(assigned_packers);
  
  -- Count busy packers
  busy_count := COALESCE(array_length(busy_packers, 1), 0);
  
  -- Build result
  IF busy_count > 0 THEN
    result := json_build_object(
      'can_resume', false,
      'busy_packers', busy_packers,
      'message', 'Some assigned packers are busy with other tasks'
    );
  ELSE
    result := json_build_object(
      'can_resume', true,
      'busy_packers', '[]'::json,
      'message', 'All assigned packers are available'
    );
  END IF;
  
  RETURN result;
END; 
$$;


ALTER FUNCTION "public"."can_resume_task"("task_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_user_mark_attendance"("order_uuid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Check if user is admin or director
  IF EXISTS (
    SELECT 1
    FROM profiles p
    JOIN roles r ON p.role_id = r.id
    WHERE p.id = auth.uid()
      AND r.name IN ('admin', 'director')
      AND p.status = 'active'
  ) THEN
    RETURN TRUE;
  END IF;
  
  -- Check if user is team lead for this order
  RETURN is_team_lead_for_order(auth.uid(), order_uuid);
END;
$$;


ALTER FUNCTION "public"."can_user_mark_attendance"("order_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_order_pkg_instance_qr"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  delete from public.qr_codes
  where entity_type = 'package'
    and entity_id = old.id;
  return old;
end;
$$;


ALTER FUNCTION "public"."cleanup_order_pkg_instance_qr"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_assignments_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  affected INTEGER := 0;
BEGIN
  IF packer_ids IS NULL OR array_length(packer_ids, 1) IS NULL THEN
    RETURN json_build_object('updated_assignments', 0);
  END IF;

  UPDATE task_assignments ta
  SET task_status = 'completed'
  FROM task_logs tl
  JOIN task_packages tp ON tp.task_log_id = tl.id
  JOIN order_packages op ON op.id = tp.order_package_id
  WHERE ta.task_id = tl.id
    AND op.order_id = order_uuid
    AND ta.packer_id = ANY(packer_ids)
    AND ta.task_status != 'completed';

  GET DIAGNOSTICS affected = ROW_COUNT;

  RETURN json_build_object('updated_assignments', affected);
END;
$$;


ALTER FUNCTION "public"."complete_assignments_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."complete_assignments_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) IS 'Marks every non-completed task assignment for the given packers as completed for a specific order.';



CREATE OR REPLACE FUNCTION "public"."complete_task"("task_log_id" "uuid") RETURNS json
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$ 
DECLARE 
  result JSON; 
  start_time_val TIMESTAMPTZ;
  restart_time_val TIMESTAMPTZ;
  current_duration NUMERIC;
  delta_minutes NUMERIC;
BEGIN 
  -- Get current task details
  SELECT start_time, restart_time, COALESCE(duration_minutes, 0)
  INTO start_time_val, restart_time_val, current_duration
  FROM task_logs 
  WHERE id = task_log_id;
  
  -- Calculate additional duration since last start/restart
  IF restart_time_val IS NOT NULL THEN
    delta_minutes := EXTRACT(EPOCH FROM (NOW() - restart_time_val)) / 60;
  ELSE
    delta_minutes := EXTRACT(EPOCH FROM (NOW() - start_time_val)) / 60;
  END IF;
  
  -- Ensure non-negative duration
  delta_minutes := GREATEST(0, delta_minutes);
  
  -- Update task log: set end_time, update duration_minutes
  UPDATE task_logs 
  SET 
    end_time = NOW(),
    duration_minutes = current_duration + delta_minutes,
    updated_at = NOW()
  WHERE id = task_log_id;
  
  -- Set all assignments for this task to completed
  UPDATE task_assignments 
  SET task_status = 'completed'
  WHERE task_id = task_log_id;
  
  -- Return success
  result := json_build_object(
    'success', true,
    'message', 'Task completed successfully',
    'duration_minutes', current_duration + delta_minutes
  );
  
  RETURN result;
END; 
$$;


ALTER FUNCTION "public"."complete_task"("task_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."count_order_team_leads"("order_uuid" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN (
    SELECT COUNT(*)::INTEGER
    FROM order_team_members
    WHERE order_id = order_uuid
      AND is_team_lead = TRUE
  );
END;
$$;


ALTER FUNCTION "public"."count_order_team_leads"("order_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_client_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select client_id from public.profiles where id = auth.uid();
$$;


ALTER FUNCTION "public"."current_client_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deactivate_expired_privileges"() RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  UPDATE temporary_privileges 
  SET is_active = false, updated_at = NOW()
  WHERE expires_at < NOW() AND is_active = true;
$$;


ALTER FUNCTION "public"."deactivate_expired_privileges"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."debug_user_info"() RETURNS TABLE("user_id" "uuid", "user_role" "text", "has_access" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ BEGIN RETURN QUERY SELECT auth.uid(), get_user_role(), (get_user_role() IN ('admin', 'director', 'project_lead', 'packer')) as has_access; END; $$;


ALTER FUNCTION "public"."debug_user_info"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decrement_item_packed_qty"("item_id" "uuid", "amount" numeric) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE public.items_db
  SET packed_qty = GREATEST(0, COALESCE(packed_qty, 0) - amount),
      updated_at = NOW()
  WHERE id = item_id;
END;
$$;


ALTER FUNCTION "public"."decrement_item_packed_qty"("item_id" "uuid", "amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_order_cascade"("order_uuid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  package_ids uuid[];
begin
  -- Collect order package ids
  select array_agg(id) into package_ids from order_packages where order_id = order_uuid;

  -- Remove task links for these packages first
  if package_ids is not null then
    delete from task_packages where order_package_id = any(package_ids);
  end if;

  -- Any task logs without any package links are now orphans: delete assignments then logs
  delete from task_assignments
    where task_id in (
      select tl.id
      from task_logs tl
      left join task_packages tp on tp.task_log_id = tl.id
      group by tl.id
      having count(tp.order_package_id) = 0
    );

  delete from task_logs tl
    where not exists (select 1 from task_packages tp where tp.task_log_id = tl.id);

  -- Delete package-level children then packages
  if package_ids is not null then
    delete from package_items where order_package_id = any(package_ids);
    delete from order_package_materials where order_package_id = any(package_ids);
    delete from order_package_securing where order_package_id = any(package_ids);
    delete from order_package_services where order_package_id = any(package_ids);
    delete from order_packages where id = any(package_ids);
  end if;

  -- Delete direct order children
  delete from attendance_logs where order_id = order_uuid;
  delete from order_team_members where order_id = order_uuid;
  delete from packer_sessions where order_id = order_uuid;
  delete from transportation where order_id = order_uuid;

  -- Finally delete the order
  delete from orders where id = order_uuid;
end;
$$;


ALTER FUNCTION "public"."delete_order_cascade"("order_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_tasks_for_order_packages"("package_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Security check: Only admin role can delete tasks
  IF NOT EXISTS (
    SELECT 1
    FROM profiles p
    JOIN roles r ON p.role_id = r.id
    WHERE p.id = auth.uid()
      AND r.name = 'admin'
      AND p.status = 'active'
  ) THEN
    RAISE EXCEPTION 'Only admin users can delete task logs';
  END IF;

  -- Delete task_logs that are associated with the given order_packages
  -- The CASCADE foreign key constraints will automatically delete:
  --   - task_packages (via task_packages.task_log_id FK)
  --   - task_assignments (via task_assignments.task_id FK)
  DELETE FROM task_logs
  WHERE id IN (
    SELECT DISTINCT task_log_id
    FROM task_packages
    WHERE order_package_id = ANY(package_ids)
      AND task_log_id IS NOT NULL
  );
END;
$$;


ALTER FUNCTION "public"."delete_tasks_for_order_packages"("package_ids" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."delete_tasks_for_order_packages"("package_ids" "uuid"[]) IS 'Deletes all task_logs associated with the given order_packages. Used by reset_packer_data functionality. CASCADE rules automatically delete task_packages and task_assignments.';



CREATE OR REPLACE FUNCTION "public"."enforce_single_active_order_for_packer"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  conflict_order_id UUID;
  conflict_order_name TEXT;
BEGIN
  IF NEW.packer_id IS NULL OR NEW.order_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT otm.order_id, o.order_name
  INTO conflict_order_id, conflict_order_name
  FROM order_team_members otm
  JOIN orders o ON o.id = otm.order_id
  WHERE otm.packer_id = NEW.packer_id
    AND otm.order_id <> NEW.order_id
    AND o.production_status <> 'completed'
  LIMIT 1;

  IF conflict_order_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Packer is already assigned to active order % (%)',
      conflict_order_name,
      conflict_order_id
      USING
        ERRCODE = '23514',
        DETAIL = 'A packer can only belong to one non-completed order at a time.',
        HINT = 'Remove the packer from the existing order first or use admin_force_release_packer.';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."enforce_single_active_order_for_packer"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."enforce_single_active_order_for_packer"() IS 'Prevents assigning a packer to multiple non-completed orders at the same time.';



CREATE OR REPLACE FUNCTION "public"."ensure_order_pkg_instance_qr"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (
    select 1
    from public.qr_codes
    where entity_type = 'package'
      and entity_id = new.id
  ) then
    insert into public.qr_codes (entity_type, entity_id)
    values ('package', new.id);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."ensure_order_pkg_instance_qr"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fetch_instance_items"("p_instance_ids" "uuid"[]) RETURNS TABLE("pkg_instance_id" "uuid", "pkd_item_id" "uuid", "quantity" numeric, "item_num" "text", "description" "text", "packed_at" timestamp with time zone, "length" numeric, "width" numeric, "height" numeric, "net_weight" numeric, "maintenance_db_id" "uuid")
    LANGUAGE "sql" STABLE
    AS $$
  SELECT 
    pi.pkg_instance_id,
    pi.id as pkd_item_id,
    pi.quantity,
    idb.item_num,
    idb.description,
    pi.created_at as packed_at,
    idb.length,
    idb.width,
    idb.height,
    idb.net_weight,
    pi.maintenance_db_id
  FROM pkd_item pi
  LEFT JOIN items_db idb ON idb.id = pi.maintenance_db_id
  WHERE pi.pkg_instance_id = ANY(p_instance_ids)
  ORDER BY pi.pkg_instance_id, idb.item_num;
$$;


ALTER FUNCTION "public"."fetch_instance_items"("p_instance_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid" DEFAULT NULL::"uuid", "p_order_id" "uuid" DEFAULT NULL::"uuid", "p_date_from" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_date_to" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_date_mode" "text" DEFAULT 'item_packed_at'::"text", "p_destinations" "text"[] DEFAULT NULL::"text"[], "p_has_items_only" boolean DEFAULT true) RETURNS TABLE("id" "uuid", "instance_number" integer, "ipac_reference" "text", "client_reference" "text", "destination" "text", "status" "text", "created_at" timestamp with time zone, "last_packed_at" timestamp with time zone, "item_count" bigint, "order_id" "uuid", "order_name" "text", "order_reference" "text", "package_number" integer, "package_reference" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    opi.id,
    opi.instance_number,
    opi.ipac_reference,
    opi.client_reference,
    opi.destination,
    -- Determine packed status based on mobile application logic
    CASE 
      WHEN op.status = 'packed' OR (COALESCE(opov.quantity_packed, 0) >= COALESCE(opov.quantity, 0) AND COALESCE(opov.quantity, 0) > 0) THEN 'packed'::text
      ELSE opi.status 
    END AS status,
    opi.created_at,
    MAX(pi.created_at) as last_packed_at,
    COUNT(pi.id) as item_count,
    o.id as order_id,
    o.order_name,
    o.reference as order_reference,
    op.package_number,
    op.reference as package_reference
  FROM order_pkg_instance opi
  INNER JOIN order_pkg_overview opov ON opov.id = opi.order_pkg_overview_id
  INNER JOIN orders o ON o.id = opov.order_id
  INNER JOIN order_packages op ON op.id = opi.order_package_id
  LEFT JOIN pkd_item pi ON pi.pkg_instance_id = opi.id
  WHERE
    -- Client/order filter
    (p_client_id IS NULL OR o.client_id = p_client_id)
    AND (p_order_id IS NULL OR o.id = p_order_id)
    -- Destination filter (pass NULL array to skip)
    AND (p_destinations IS NULL OR array_length(p_destinations, 1) = 0 OR opi.destination = ANY(p_destinations))
  GROUP BY 
    opi.id, opi.instance_number, opi.ipac_reference, opi.client_reference,
    opi.destination, opi.status, opi.created_at,
    o.id, o.order_name, o.reference,
    op.package_number, op.reference,
    op.status, opov.quantity, opov.quantity_packed
  HAVING
    -- Items filter
    (NOT p_has_items_only OR COUNT(pi.id) > 0)
    -- Date range filtering
    AND (
      p_date_from IS NULL OR (
        CASE 
          WHEN p_date_mode = 'item_packed_at' THEN MAX(pi.created_at) >= p_date_from
          ELSE opi.created_at >= p_date_from
        END
      )
    )
    AND (
      p_date_to IS NULL OR (
        CASE 
          WHEN p_date_mode = 'item_packed_at' THEN MAX(pi.created_at) <= p_date_to
          ELSE opi.created_at <= p_date_to
        END
      )
    )
  ORDER BY last_packed_at DESC NULLS LAST, opi.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_id" "uuid", "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid" DEFAULT NULL::"uuid", "p_order_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_date_from" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_date_to" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_date_mode" "text" DEFAULT 'item_packed_at'::"text", "p_destinations" "text"[] DEFAULT NULL::"text"[], "p_has_items_only" boolean DEFAULT true, "p_order_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "instance_number" integer, "ipac_reference" "text", "client_reference" "text", "destination" "text", "status" "text", "created_at" timestamp with time zone, "last_packed_at" timestamp with time zone, "item_count" bigint, "order_id" "uuid", "order_name" "text", "order_reference" "text", "package_number" integer, "package_reference" "text")
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_order_ids uuid[];
BEGIN
  -- Resolve effective order IDs: prefer p_order_ids array, fall back to single p_order_id
  IF p_order_ids IS NOT NULL AND array_length(p_order_ids, 1) > 0 THEN
    v_order_ids := p_order_ids;
  ELSIF p_order_id IS NOT NULL THEN
    v_order_ids := ARRAY[p_order_id];
  ELSE
    v_order_ids := NULL;
  END IF;

  RETURN QUERY
  SELECT 
    opi.id,
    opi.instance_number,
    opi.ipac_reference,
    opi.client_reference,
    opi.destination,
    CASE 
      WHEN op.status = 'packed' OR (COALESCE(opov.quantity_packed, 0) >= COALESCE(opov.quantity, 0) AND COALESCE(opov.quantity, 0) > 0) THEN 'packed'::text
      ELSE opi.status 
    END AS status,
    opi.created_at,
    MAX(pi.created_at) as last_packed_at,
    COUNT(pi.id) as item_count,
    o.id as order_id,
    o.order_name,
    o.reference as order_reference,
    op.package_number,
    op.reference as package_reference
  FROM order_pkg_instance opi
  INNER JOIN order_pkg_overview opov ON opov.id = opi.order_pkg_overview_id
  INNER JOIN orders o ON o.id = opov.order_id
  INNER JOIN order_packages op ON op.id = opi.order_package_id
  LEFT JOIN pkd_item pi ON pi.pkg_instance_id = opi.id
  WHERE
    (p_client_id IS NULL OR o.client_id = p_client_id)
    AND (v_order_ids IS NULL OR o.id = ANY(v_order_ids))
    AND (p_destinations IS NULL OR array_length(p_destinations, 1) = 0 OR opi.destination = ANY(p_destinations))
  GROUP BY 
    opi.id, opi.instance_number, opi.ipac_reference, opi.client_reference,
    opi.destination, opi.status, opi.created_at,
    o.id, o.order_name, o.reference,
    op.package_number, op.reference,
    op.status, opov.quantity, opov.quantity_packed
  HAVING
    (NOT p_has_items_only OR COUNT(pi.id) > 0)
    AND (
      p_date_from IS NULL OR (
        CASE 
          WHEN p_date_mode = 'item_packed_at' THEN MAX(pi.created_at) >= p_date_from
          ELSE opi.created_at >= p_date_from
        END
      )
    )
    AND (
      p_date_to IS NULL OR (
        CASE 
          WHEN p_date_mode = 'item_packed_at' THEN MAX(pi.created_at) <= p_date_to
          ELSE opi.created_at <= p_date_to
        END
      )
    )
  ORDER BY last_packed_at DESC NULLS LAST, opi.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean, "p_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid" DEFAULT NULL::"uuid", "p_order_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_date_from" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_date_to" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_date_mode" "text" DEFAULT 'item_packed_at'::"text", "p_destinations" "text"[] DEFAULT NULL::"text"[], "p_has_items_only" boolean DEFAULT true, "p_order_id" "uuid" DEFAULT NULL::"uuid", "p_tag_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS TABLE("id" "uuid", "instance_number" integer, "ipac_reference" "text", "client_reference" "text", "destination" "text", "status" "text", "created_at" timestamp with time zone, "last_packed_at" timestamp with time zone, "item_count" bigint, "order_id" "uuid", "order_name" "text", "order_reference" "text", "package_number" integer, "package_reference" "text")
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_order_ids uuid[];
BEGIN
  IF p_order_ids IS NOT NULL AND array_length(p_order_ids, 1) > 0 THEN
    v_order_ids := p_order_ids;
  ELSIF p_order_id IS NOT NULL THEN
    v_order_ids := ARRAY[p_order_id];
  ELSE
    v_order_ids := NULL;
  END IF;

  RETURN QUERY
  WITH task_completed AS (
    SELECT
      tp.order_package_id,
      MAX(tl.end_time) AS last_task_completed_at
    FROM public.task_packages tp
    INNER JOIN public.task_logs tl ON tl.id = tp.task_log_id
    WHERE tl.end_time IS NOT NULL
    GROUP BY tp.order_package_id
  )
  SELECT
    opi.id,
    opi.instance_number,
    opi.ipac_reference,
    opi.client_reference,
    opi.destination,
    CASE
      WHEN op.status = 'packed'
        OR (
          COALESCE(opov.quantity_packed, 0) >= COALESCE(opov.quantity, 0)
          AND COALESCE(opov.quantity, 0) > 0
        )
      THEN 'packed'::text
      ELSE opi.status
    END AS status,
    opi.created_at,
    COALESCE(opi.packed_at, tc.last_task_completed_at, MAX(pi.created_at)) AS last_packed_at,
    COUNT(pi.id) AS item_count,
    o.id AS order_id,
    o.order_name,
    o.reference AS order_reference,
    op.package_number,
    op.reference AS package_reference
  FROM public.order_pkg_instance opi
  INNER JOIN public.order_pkg_overview opov ON opov.id = opi.order_pkg_overview_id
  INNER JOIN public.orders o ON o.id = opov.order_id
  INNER JOIN public.order_packages op ON op.id = opi.order_package_id
  LEFT JOIN public.pkd_item pi ON pi.pkg_instance_id = opi.id
  LEFT JOIN task_completed tc ON tc.order_package_id = opi.order_package_id
  WHERE
    (p_client_id IS NULL OR o.client_id = p_client_id)
    AND (v_order_ids IS NULL OR o.id = ANY(v_order_ids))
    AND (
      p_destinations IS NULL
      OR array_length(p_destinations, 1) = 0
      OR opi.destination = ANY(p_destinations)
    )
    AND (
      p_tag_ids IS NULL
      OR array_length(p_tag_ids, 1) = 0
      OR opi.category_id IN (
        SELECT ctm.category_id
        FROM public.category_tag_map ctm
        WHERE ctm.tag_id = ANY(p_tag_ids)
      )
    )
  GROUP BY
    opi.id,
    opi.instance_number,
    opi.ipac_reference,
    opi.client_reference,
    opi.destination,
    opi.status,
    opi.created_at,
    opi.packed_at,
    o.id,
    o.order_name,
    o.reference,
    op.package_number,
    op.reference,
    op.status,
    opov.quantity,
    opov.quantity_packed,
    tc.last_task_completed_at
  HAVING
    (NOT p_has_items_only OR COUNT(pi.id) > 0)
    AND (
      p_date_from IS NULL
      OR (
        CASE p_date_mode
          WHEN 'packing_started_at' THEN MIN(pi.created_at)
          WHEN 'packing_completed_at' THEN COALESCE(opi.packed_at, tc.last_task_completed_at, MAX(pi.created_at))
          WHEN 'item_packed_at' THEN COALESCE(opi.packed_at, tc.last_task_completed_at, MAX(pi.created_at))
          ELSE opi.created_at
        END
      ) >= p_date_from
    )
    AND (
      p_date_to IS NULL
      OR (
        CASE p_date_mode
          WHEN 'packing_started_at' THEN MIN(pi.created_at)
          WHEN 'packing_completed_at' THEN COALESCE(opi.packed_at, tc.last_task_completed_at, MAX(pi.created_at))
          WHEN 'item_packed_at' THEN COALESCE(opi.packed_at, tc.last_task_completed_at, MAX(pi.created_at))
          ELSE opi.created_at
        END
      ) <= p_date_to
    )
  ORDER BY last_packed_at DESC NULLS LAST, opi.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean, "p_order_id" "uuid", "p_tag_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_active_tasks_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) RETURNS TABLE("task_log_id" "uuid", "task_name" "text", "packer_id" "uuid", "task_status" "text", "package_numbers" "text"[])
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
BEGIN
  IF packer_ids IS NULL OR array_length(packer_ids, 1) IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    tl.id AS task_log_id,
    t.name AS task_name,
    ta.packer_id,
    ta.task_status::text,
    ARRAY_AGG(DISTINCT op.package_number ORDER BY op.package_number) AS package_numbers
  FROM task_assignments ta
  JOIN task_logs tl ON tl.id = ta.task_id
  JOIN tasks t ON t.id = tl.task_id
  JOIN task_packages tp ON tp.task_log_id = tl.id
  JOIN order_packages op ON op.id = tp.order_package_id
  WHERE op.order_id = order_uuid
    AND ta.packer_id = ANY(packer_ids)
    AND ta.task_status != 'completed'
  GROUP BY tl.id, t.name, ta.packer_id, ta.task_status;
END;
$$;


ALTER FUNCTION "public"."get_active_tasks_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_active_tasks_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) IS 'Returns active task summaries (with boxes) for the specified packers on an order.';



CREATE OR REPLACE FUNCTION "public"."get_all_packers_with_status"() RETURNS TABLE("id" "uuid", "full_name" "text", "username" "text", "packer_status" "text", "current_order_id" "uuid", "current_order_name" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        p.id,
        p.full_name,
        p.username,
        p.packer_status,
        p.current_order_id,
        o.order_name as current_order_name
    FROM public.profiles p
    JOIN public.roles r ON p.role_id = r.id
    LEFT JOIN public.orders o ON p.current_order_id = o.id
    WHERE r.name = 'packer'
    AND p.status = 'active'
    ORDER BY p.full_name;
END;
$$;


ALTER FUNCTION "public"."get_all_packers_with_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_available_packers"() RETURNS TABLE("id" "uuid", "full_name" "text", "username" "text", "packer_status" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT p.id, p.full_name, p.username, p.packer_status
    FROM public.profiles p
    JOIN public.roles r ON p.role_id = r.id
    WHERE r.name = 'packer' 
    AND p.status = 'active'
    AND p.packer_status = 'available';
END;
$$;


ALTER FUNCTION "public"."get_available_packers"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_busy_packers"() RETURNS TABLE("id" "uuid", "full_name" "text", "username" "text", "current_order_name" "text", "current_order_id" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT p.id, p.full_name, p.username, o.order_name, p.current_order_id
    FROM public.profiles p
    JOIN public.roles r ON p.role_id = r.id
    LEFT JOIN public.orders o ON p.current_order_id = o.id
    WHERE r.name = 'packer' 
    AND p.status = 'active'
    AND p.packer_status = 'busy';
END;
$$;


ALTER FUNCTION "public"."get_busy_packers"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_order_packers"("order_uuid" "uuid") RETURNS TABLE("packer_id" "uuid", "full_name" "text", "username" "text", "packer_status" "text", "assigned_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ BEGIN RETURN QUERY SELECT p.id, p.full_name, p.username, p.packer_status, otm.created_at FROM public.order_team_members otm JOIN public.profiles p ON otm.packer_id = p.id WHERE otm.order_id = order_uuid ORDER BY otm.created_at ASC; END; $$;


ALTER FUNCTION "public"."get_order_packers"("order_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_order_progress"("order_uuid" "uuid") RETURNS TABLE("total_packages" bigint, "total_boxes" bigint, "completed_boxes" bigint, "completion_percentage" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COUNT(*) as total_packages,
        SUM(op.quantity) as total_boxes,
        SUM(op.boxes_completed) as completed_boxes,
        CASE 
            WHEN SUM(op.quantity) > 0 THEN 
                ROUND((SUM(op.boxes_completed)::NUMERIC / SUM(op.quantity)::NUMERIC) * 100, 2)
            ELSE 0
        END as completion_percentage
    FROM public.order_packages op
    WHERE op.order_id = order_uuid;
END;
$$;


ALTER FUNCTION "public"."get_order_progress"("order_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_order_team_leads"("order_uuid" "uuid") RETURNS TABLE("packer_id" "uuid", "full_name" "text", "username" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    otm.packer_id,
    p.full_name,
    p.username
  FROM order_team_members otm
  JOIN profiles p ON p.id = otm.packer_id
  WHERE otm.order_id = order_uuid
    AND otm.is_team_lead = TRUE;
END;
$$;


ALTER FUNCTION "public"."get_order_team_leads"("order_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_packer_assignment_status"() RETURNS TABLE("packer_id" "uuid", "full_name" "text", "username" "text", "packer_status" "text", "current_order_id" "uuid", "current_order_name" "text", "active_orders" integer, "active_sessions" integer, "open_attendance" integer, "active_tasks" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  SELECT
    p.id AS packer_id,
    p.full_name,
    p.username,
    p.packer_status,
    p.current_order_id,
    o.order_name AS current_order_name,
    COALESCE(otm_counts.active_orders, 0)::INTEGER AS active_orders,
    COALESCE(session_counts.active_sessions, 0)::INTEGER AS active_sessions,
    COALESCE(attendance_counts.open_attendance, 0)::INTEGER AS open_attendance,
    COALESCE(task_counts.active_tasks, 0)::INTEGER AS active_tasks
  FROM profiles p
  JOIN roles r ON r.id = p.role_id
  LEFT JOIN orders o ON o.id = p.current_order_id
  LEFT JOIN (
    SELECT order_team_members.packer_id, COUNT(*) AS active_orders
    FROM order_team_members
    GROUP BY order_team_members.packer_id
  ) otm_counts ON otm_counts.packer_id = p.id
  LEFT JOIN (
    SELECT packer_sessions.packer_id, COUNT(*) AS active_sessions
    FROM packer_sessions
    WHERE session_active = TRUE
    GROUP BY packer_sessions.packer_id
  ) session_counts ON session_counts.packer_id = p.id
  LEFT JOIN (
    SELECT attendance_logs.packer_id, COUNT(*) AS open_attendance
    FROM attendance_logs
    WHERE end_time IS NULL
    GROUP BY attendance_logs.packer_id
  ) attendance_counts ON attendance_counts.packer_id = p.id
  LEFT JOIN (
    SELECT task_assignments.packer_id, COUNT(*) AS active_tasks
    FROM task_assignments
    WHERE task_status <> 'completed'
    GROUP BY task_assignments.packer_id
  ) task_counts ON task_counts.packer_id = p.id
  WHERE r.name = 'packer'
  ORDER BY p.full_name;
$$;


ALTER FUNCTION "public"."get_packer_assignment_status"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_packer_assignment_status"() IS 'Returns admin-friendly packer assignment/session/task summary rows for freeing packers.';



CREATE OR REPLACE FUNCTION "public"."get_user_email_by_username"("lookup_username" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    user_email TEXT;
BEGIN
    -- Look up the email for the given username by joining profiles and auth.users
    SELECT au.email INTO user_email
    FROM profiles p
    JOIN auth.users au ON p.id = au.id
    WHERE p.username = lookup_username
    LIMIT 1;
    
    -- Return the email if found, NULL otherwise
    RETURN user_email;
END;
$$;


ALTER FUNCTION "public"."get_user_email_by_username"("lookup_username" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_user_email_by_username"("lookup_username" "text") IS 'Securely lookup user email by username for authentication purposes. 
Runs with elevated privileges to bypass RLS policies.';



CREATE OR REPLACE FUNCTION "public"."get_user_role"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    user_role TEXT;
BEGIN
    -- Fetch the role name for the current authenticated user
    SELECT r.name INTO user_role
    FROM public.profiles p
    JOIN public.roles r ON p.role_id = r.id
    WHERE p.id = auth.uid()
    AND p.status = 'active';
    
    RETURN COALESCE(user_role, 'unknown');
END;
$$;


ALTER FUNCTION "public"."get_user_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_profile_security_fields"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  actor_id uuid := (select auth.uid());
  actor_role text;
  jwt_role text := coalesce((select auth.jwt() ->> 'role'), '');
begin
  if new.id is distinct from old.id then
    raise exception 'Profile ID cannot be changed'
      using errcode = '42501';
  end if;

  if new.role_id is not distinct from old.role_id
     and new.client_id is not distinct from old.client_id
     and new.status is not distinct from old.status then
    return new;
  end if;

  -- Trusted server and database-maintenance roles remain operational.
  if jwt_role = 'service_role'
     or current_user in ('service_role', 'postgres', 'supabase_admin') then
    return new;
  end if;

  if actor_id is null then
    raise exception 'Authentication required'
      using errcode = '42501';
  end if;

  -- On self-updates, always authorize from the stored pre-update role.
  if old.id = actor_id then
    select r.name
      into actor_role
      from public.roles r
     where r.id = old.role_id;
  else
    select r.name
      into actor_role
      from public.profiles p
      join public.roles r on r.id = p.role_id
     where p.id = actor_id;
  end if;

  -- Only admin/director may change role or tenant assignment.
  if new.role_id is distinct from old.role_id
     or new.client_id is distinct from old.client_id then
    if actor_role is null
       or actor_role not in ('admin', 'director') then
      raise exception 'Not authorized to change role_id or client_id'
        using errcode = '42501';
    end if;
  end if;

  -- Preserve the existing project-lead can_block_users workflow for status changes.
  if new.status is distinct from old.status then
    if actor_role is null
       or (
         actor_role not in ('admin', 'director')
         and not (
           actor_role = 'project_lead'
           and public.user_has_permission('can_block_users')
         )
       ) then
      raise exception 'Not authorized to change profile status'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."guard_profile_security_fields"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."guard_profile_security_fields"() IS 'Prevents self-escalation through profiles.role_id, client_id, or status.';



CREATE OR REPLACE FUNCTION "public"."handle_empty_order"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  packer_count INTEGER;
BEGIN
  SELECT COUNT(*)
  INTO packer_count
  FROM order_team_members
  WHERE order_id = OLD.order_id;

  IF packer_count = 0 THEN
    UPDATE orders
    SET production_status = 'pending',
        project_lead_id = NULL,
        updated_at = now()
    WHERE id = OLD.order_id
      AND production_status <> 'completed';
  END IF;

  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."handle_empty_order"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."handle_empty_order"() IS 'Resets order status to pending when the last packer is removed so teams can reassign quickly.';



CREATE OR REPLACE FUNCTION "public"."increment_item_packed_qty"("item_id" "uuid", "amount" numeric) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE public.items_db
  SET packed_qty = COALESCE(packed_qty, 0) + amount,
      updated_at = NOW()
  WHERE id = item_id;
END;
$$;


ALTER FUNCTION "public"."increment_item_packed_qty"("item_id" "uuid", "amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_my_client_instance"("p_instance_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.order_pkg_instance i
    left join public.order_pkg_overview ov on ov.id = i.order_pkg_overview_id
    where i.id = p_instance_id
      and ( public.is_my_client_order(ov.order_id)
         or (i.order_package_id is not null and public.is_my_client_package(i.order_package_id))));
$$;


ALTER FUNCTION "public"."is_my_client_instance"("p_instance_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_my_client_order"("p_order_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.orders o
    where o.id = p_order_id and o.client_id = public.current_client_id());
$$;


ALTER FUNCTION "public"."is_my_client_order"("p_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_my_client_package"("p_pkg_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.order_packages p
    where p.id = p_pkg_id and public.is_my_client_order(p.order_id));
$$;


ALTER FUNCTION "public"."is_my_client_package"("p_pkg_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_staff_or_packer"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.get_user_role() = any (array[
    'admin','director','executive','sales','project_lead','packer']);
$$;


ALTER FUNCTION "public"."is_staff_or_packer"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_team_lead_for_order"("user_id" "uuid", "order_uuid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM order_team_members otm
    WHERE otm.packer_id = user_id
      AND otm.order_id = order_uuid
      AND otm.is_team_lead = TRUE
  );
END;
$$;


ALTER FUNCTION "public"."is_team_lead_for_order"("user_id" "uuid", "order_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_packer_status_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
    -- Log packer status changes to audit log
    IF OLD.packer_status IS DISTINCT FROM NEW.packer_status THEN
        INSERT INTO public.audit_log (
            entity_type,
            entity_id,
            column_name,
            old_value,
            new_value,
            changed_by,
            action_type,
            notes
        ) VALUES (
            'profile',
            NEW.id,
            'packer_status',
            to_jsonb(OLD.packer_status),
            to_jsonb(NEW.packer_status),
            COALESCE(auth.uid(), NEW.id), -- Use NEW.id if auth.uid() is null (for system updates)
            'UPDATE',
            'Packer status changed'
        );
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."log_packer_status_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_order_package_packed"("op_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  UPDATE order_packages
  SET status = 'packed',
      updated_at = NOW()
  WHERE id = op_id;
END;
$$;


ALTER FUNCTION "public"."mark_order_package_packed"("op_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."order_has_team_lead"("order_uuid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM order_team_members
    WHERE order_id = order_uuid
      AND is_team_lead = TRUE
  );
END;
$$;


ALTER FUNCTION "public"."order_has_team_lead"("order_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."packer_logged_attendance_today"("order_uuid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.attendance_logs 
    WHERE order_id = order_uuid 
    AND packer_id = auth.uid() 
    AND log_date = CURRENT_DATE
  );
END;
$$;


ALTER FUNCTION "public"."packer_logged_attendance_today"("order_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."packer_needs_daily_attendance"("packer_uuid" "uuid", "order_uuid" "uuid", "check_date" "date" DEFAULT CURRENT_DATE) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    -- Check if packer has logged attendance for today on this order
    RETURN NOT EXISTS (
        SELECT 1 FROM public.attendance_logs 
        WHERE packer_id = packer_uuid 
        AND order_id = order_uuid 
        AND log_date = check_date
    );
END;
$$;


ALTER FUNCTION "public"."packer_needs_daily_attendance"("packer_uuid" "uuid", "order_uuid" "uuid", "check_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pause_task"("task_log_id" "uuid") RETURNS json
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$ 
DECLARE 
  result JSON; 
  start_time_val TIMESTAMPTZ;
  restart_time_val TIMESTAMPTZ;
  current_duration NUMERIC;
  current_pause NUMERIC;
  delta_minutes NUMERIC;
BEGIN 
  -- Get current task details
  SELECT start_time, restart_time, 
         COALESCE(duration_minutes, 0), 
         COALESCE(pause_duration, 0)
  INTO start_time_val, restart_time_val, current_duration, current_pause
  FROM task_logs 
  WHERE id = task_log_id;
  
  -- Calculate duration since last start/restart
  IF restart_time_val IS NOT NULL THEN
    delta_minutes := EXTRACT(EPOCH FROM (NOW() - restart_time_val)) / 60;
  ELSE
    delta_minutes := EXTRACT(EPOCH FROM (NOW() - start_time_val)) / 60;
  END IF;
  
  -- Ensure non-negative duration
  delta_minutes := GREATEST(0, delta_minutes);
  
  -- Update task log: add to duration_minutes, set pause start time
  UPDATE task_logs 
  SET 
    duration_minutes = current_duration + delta_minutes,
    restart_time = NULL, -- Clear restart time when pausing
    update_counter = COALESCE(update_counter, 0) + 1,
    updated_at = NOW()
  WHERE id = task_log_id;
  
  -- Set all assignments for this task to paused
  UPDATE task_assignments 
  SET task_status = 'paused'
  WHERE task_id = task_log_id;
  
  -- Return success with pause timestamp
  result := json_build_object(
    'success', true,
    'message', 'Task paused successfully',
    'pause_start_time', NOW(),
    'accumulated_minutes', current_duration + delta_minutes
  );
  
  RETURN result;
END; 
$$;


ALTER FUNCTION "public"."pause_task"("task_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_alloc_packed"("p_item" "uuid", "p_instance" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_order uuid;
  v_dest_id uuid;
BEGIN
  IF p_item IS NULL OR p_instance IS NULL THEN RETURN; END IF;

  SELECT ov.order_id,
         coalesce(
           (SELECT d.id FROM destinations d
             WHERE d.code = upper(coalesce(nullif(btrim(i.destination), ''), 'UNASSIGNED'))),
           (SELECT du.id FROM destinations du WHERE du.code = 'UNASSIGNED')
         )
  INTO v_order, v_dest_id
  FROM order_pkg_instance i
  JOIN order_pkg_overview ov ON ov.id = i.order_pkg_overview_id
  WHERE i.id = p_instance;

  PERFORM public.recompute_alloc_packed_key(v_order, p_item, v_dest_id);
END;
$$;


ALTER FUNCTION "public"."recompute_alloc_packed"("p_item" "uuid", "p_instance" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_alloc_packed_key"("p_order" "uuid", "p_item" "uuid", "p_dest_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF p_order IS NULL OR p_item IS NULL OR p_dest_id IS NULL THEN RETURN; END IF;

  UPDATE order_item_allocation a
  SET packed_qty = coalesce((
    SELECT sum(pi.quantity)
    FROM pkd_item pi
    JOIN order_pkg_instance i2 ON i2.id = pi.pkg_instance_id
    JOIN order_pkg_overview ov2 ON ov2.id = i2.order_pkg_overview_id
    WHERE pi.maintenance_db_id = p_item
      AND pi.is_confirmed
      AND ov2.order_id = p_order
      AND coalesce(
        (SELECT d2.id FROM destinations d2
          WHERE d2.code = upper(coalesce(nullif(btrim(i2.destination), ''), 'UNASSIGNED'))),
        (SELECT du.id FROM destinations du WHERE du.code = 'UNASSIGNED')
      ) = p_dest_id
  ), 0), updated_at = now()
  WHERE a.order_id = p_order AND a.items_db_id = p_item AND a.destination_id = p_dest_id;
END;
$$;


ALTER FUNCTION "public"."recompute_alloc_packed_key"("p_order" "uuid", "p_item" "uuid", "p_dest_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_order_pkg_overview_rollup"("p_overview_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_total integer := 0;
  v_packed integer := 0;
BEGIN
  SELECT
    COUNT(*)::integer,
    COUNT(*) FILTER (WHERE status = 'packed')::integer
  INTO v_total, v_packed
  FROM public.order_pkg_instance
  WHERE order_pkg_overview_id = p_overview_id;

  UPDATE public.order_pkg_overview o
  SET
    quantity_packed = v_packed,
    status = CASE
      WHEN v_total = 0 THEN o.status
      WHEN v_packed = 0 THEN 'approved'
      WHEN v_packed < v_total THEN 'in_production'
      ELSE 'packed'
    END,
    updated_at = now()
  WHERE o.id = p_overview_id;
END;
$$;


ALTER FUNCTION "public"."refresh_order_pkg_overview_rollup"("p_overview_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_allocation_increase_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  req public.allocation_increase_requests%ROWTYPE;
BEGIN
  SELECT * INTO req FROM allocation_increase_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Allocation increase request % not found', p_request_id; END IF;

  INSERT INTO request_audit_log
    (request_type, action, request_snapshot, requested_by, requested_at,
     reviewed_by, reviewed_at, admin_notes, resulting_id, order_package_context)
  VALUES ('allocation_increase', 'rejected', to_jsonb(req), req.requested_by, req.requested_at,
          p_reviewed_by, now(), p_admin_notes, NULL, req.order_package_context);

  DELETE FROM allocation_increase_requests WHERE id = p_request_id;
END;
$$;


ALTER FUNCTION "public"."reject_allocation_increase_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_material_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_req material_requests%ROWTYPE;
BEGIN
  SELECT * INTO v_req FROM material_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'material_request % not found', p_request_id;
  END IF;

  INSERT INTO request_audit_log (
    request_type, action, request_snapshot,
    requested_by, requested_at,
    reviewed_by, reviewed_at,
    admin_notes, resulting_id, order_package_context
  ) VALUES (
    'material', 'rejected', to_jsonb(v_req),
    v_req.requested_by, v_req.requested_at,
    p_reviewed_by, now(),
    p_admin_notes, NULL, v_req.order_package_context
  );

  -- CASCADE will delete dependent material_variant_requests and their
  -- dependent supplier_pricing_requests automatically
  DELETE FROM material_requests WHERE id = p_request_id;
END;
$$;


ALTER FUNCTION "public"."reject_material_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_material_variant_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_req material_variant_requests%ROWTYPE;
BEGIN
  SELECT * INTO v_req FROM material_variant_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'material_variant_request % not found', p_request_id;
  END IF;

  INSERT INTO request_audit_log (
    request_type, action, request_snapshot,
    requested_by, requested_at,
    reviewed_by, reviewed_at,
    admin_notes, resulting_id, order_package_context
  ) VALUES (
    'material_variant', 'rejected', to_jsonb(v_req),
    v_req.requested_by, v_req.requested_at,
    p_reviewed_by, now(),
    p_admin_notes, NULL, v_req.order_package_context
  );

  -- CASCADE deletes dependent supplier_pricing_requests automatically
  DELETE FROM material_variant_requests WHERE id = p_request_id;
END;
$$;


ALTER FUNCTION "public"."reject_material_variant_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_supplier_pricing_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_req supplier_pricing_requests%ROWTYPE;
BEGIN
  SELECT * INTO v_req FROM supplier_pricing_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'supplier_pricing_request % not found', p_request_id;
  END IF;

  INSERT INTO request_audit_log (
    request_type, action, request_snapshot,
    requested_by, requested_at,
    reviewed_by, reviewed_at,
    admin_notes, resulting_id, order_package_context
  ) VALUES (
    'supplier_pricing', 'rejected', to_jsonb(v_req),
    v_req.requested_by, v_req.requested_at,
    p_reviewed_by, now(),
    p_admin_notes, NULL, v_req.order_package_context
  );

  DELETE FROM supplier_pricing_requests WHERE id = p_request_id;
END;
$$;


ALTER FUNCTION "public"."reject_supplier_pricing_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_self_from_order"("order_uuid" "uuid", "packer_uuid" "uuid") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  packer_record RECORD;
  remaining_count INTEGER := 0;
  was_lead BOOLEAN := FALSE;
BEGIN
  SELECT otm.is_team_lead
  INTO packer_record
  FROM order_team_members otm
  WHERE otm.order_id = order_uuid AND otm.packer_id = packer_uuid;

  IF NOT FOUND THEN
    RETURN json_build_object(
      'success', false,
      'error', 'not_assigned',
      'message', 'You are not assigned to this order'
    );
  END IF;

  was_lead := COALESCE(packer_record.is_team_lead, FALSE);

  PERFORM complete_assignments_for_packers(order_uuid, ARRAY[packer_uuid]);

  UPDATE attendance_logs
  SET end_time = COALESCE(end_time, now()),
      updated_at = now()
  WHERE order_id = order_uuid
    AND packer_id = packer_uuid
    AND end_time IS NULL;

  DELETE FROM order_team_members
  WHERE order_id = order_uuid AND packer_id = packer_uuid;

  UPDATE packer_sessions
  SET session_active = FALSE,
      updated_at = now()
  WHERE order_id = order_uuid
    AND packer_id = packer_uuid
    AND session_active = TRUE;

  UPDATE profiles
  SET packer_status = 'available',
      current_order_id = NULL,
      updated_at = now()
  WHERE id = packer_uuid;

  SELECT COUNT(*) INTO remaining_count
  FROM order_team_members
  WHERE order_id = order_uuid;

  IF remaining_count = 0 THEN
    UPDATE orders
    SET production_status = 'pending',
        project_lead_id = NULL,
        updated_at = now()
    WHERE id = order_uuid
      AND production_status <> 'completed';
  END IF;

  RETURN json_build_object(
    'success', true,
    'remaining_packers', remaining_count,
    'was_lead', was_lead
  );
END;
$$;


ALTER FUNCTION "public"."remove_self_from_order"("order_uuid" "uuid", "packer_uuid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."remove_self_from_order"("order_uuid" "uuid", "packer_uuid" "uuid") IS 'Removes the requesting packer from an order, allows last-member removal, and resets empty non-completed orders to pending.';



CREATE OR REPLACE FUNCTION "public"."remove_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  UPDATE order_team_members
  SET is_team_lead = FALSE
  WHERE order_id = order_uuid
    AND packer_id = packer_uuid
    AND is_team_lead = TRUE;
END;
$$;


ALTER FUNCTION "public"."remove_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resume_task"("task_log_id" "uuid") RETURNS json
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$ 
DECLARE 
  result JSON; 
  can_resume_result JSON;
BEGIN 
  -- Check if task can be resumed
  SELECT can_resume_task(task_log_id) INTO can_resume_result;
  
  -- If can't resume, return the result
  IF NOT (can_resume_result->>'can_resume')::boolean THEN
    RETURN can_resume_result;
  END IF;
  
  -- Resume the task: clear end_time, set restart_time, increment update_counter
  UPDATE task_logs 
  SET 
    end_time = NULL,
    restart_time = NOW(),
    update_counter = COALESCE(update_counter, 0) + 1,
    updated_at = NOW()
  WHERE id = task_log_id;
  
  -- Set all assignments for this task back to in_progress
  UPDATE task_assignments 
  SET task_status = 'in_progress'
  WHERE task_id = task_log_id;
  
  -- Return success
  result := json_build_object(
    'success', true,
    'message', 'Task resumed successfully'
  );
  
  RETURN result;
END; 
$$;


ALTER FUNCTION "public"."resume_task"("task_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_allocation_expected"("p_allocation_id" "uuid", "p_expected" numeric) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE v_old numeric; v_item uuid;
BEGIN
  IF p_expected IS NULL OR p_expected < 0 THEN RAISE EXCEPTION 'expected_qty must be >= 0'; END IF;
  IF p_expected <> floor(p_expected) THEN RAISE EXCEPTION 'expected_qty must be a whole number'; END IF;
  SELECT expected_qty, items_db_id INTO v_old, v_item FROM order_item_allocation WHERE id = p_allocation_id;
  IF v_item IS NULL THEN RAISE EXCEPTION 'allocation % not found', p_allocation_id; END IF;
  UPDATE order_item_allocation SET expected_qty = p_expected, updated_at = now() WHERE id = p_allocation_id;
  UPDATE items_db SET expected_qty = GREATEST(0, COALESCE(expected_qty,0) + (p_expected - COALESCE(v_old,0))), updated_at = now() WHERE id = v_item;
END; $$;


ALTER FUNCTION "public"."set_allocation_expected"("p_allocation_id" "uuid", "p_expected" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_maintenance_task_assignments_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_maintenance_task_assignments_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_maintenance_task_log_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_maintenance_task_log_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_order_pkg_instance_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_order_pkg_instance_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_order_pkg_overview_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_order_pkg_overview_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."stamp_instance_packed_at_on_package_packed"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.status = 'packed'
     AND OLD.status IS DISTINCT FROM 'packed' THEN
    UPDATE public.order_pkg_instance
    SET packed_at = COALESCE(packed_at, now())
    WHERE order_package_id = NEW.id
      AND packed_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."stamp_instance_packed_at_on_package_packed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_profile_on_order_team_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Mark packer busy and set current order
    UPDATE profiles
    SET packer_status = 'busy',
        current_order_id = NEW.order_id
    WHERE id = NEW.packer_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    -- Remove any sessions for this order (full delete as requested)
    DELETE FROM packer_sessions
    WHERE packer_id = OLD.packer_id
      AND order_id = OLD.order_id;

    -- If the packer is not assigned to any other order, set available and clear current_order_id
    IF NOT EXISTS (SELECT 1 FROM order_team_members WHERE packer_id = OLD.packer_id) THEN
      UPDATE profiles
      SET packer_status = 'available',
          current_order_id = NULL
      WHERE id = OLD.packer_id;
    END IF;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."sync_profile_on_order_team_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_instance_destination_packed_sync"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_order uuid;
  v_old_dest uuid;
  v_new_dest uuid;
  r record;
BEGIN
  SELECT ov.order_id INTO v_order
  FROM order_pkg_overview ov WHERE ov.id = NEW.order_pkg_overview_id;
  IF v_order IS NULL THEN RETURN NULL; END IF;

  v_old_dest := coalesce(
    (SELECT id FROM destinations WHERE code = upper(coalesce(nullif(btrim(OLD.destination), ''), 'UNASSIGNED'))),
    (SELECT id FROM destinations WHERE code = 'UNASSIGNED'));
  v_new_dest := coalesce(
    (SELECT id FROM destinations WHERE code = upper(coalesce(nullif(btrim(NEW.destination), ''), 'UNASSIGNED'))),
    (SELECT id FROM destinations WHERE code = 'UNASSIGNED'));

  FOR r IN
    SELECT DISTINCT maintenance_db_id
    FROM pkd_item
    WHERE pkg_instance_id = NEW.id AND maintenance_db_id IS NOT NULL
  LOOP
    PERFORM public.recompute_alloc_packed_key(v_order, r.maintenance_db_id, v_old_dest);
    PERFORM public.recompute_alloc_packed_key(v_order, r.maintenance_db_id, v_new_dest);
  END LOOP;

  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."trg_instance_destination_packed_sync"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_order_pkg_instance_rollup"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_overview_id uuid;
BEGIN
  v_overview_id := COALESCE(NEW.order_pkg_overview_id, OLD.order_pkg_overview_id);

  IF v_overview_id IS NOT NULL THEN
    PERFORM public.refresh_order_pkg_overview_rollup(v_overview_id);
  END IF;

  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."trg_order_pkg_instance_rollup"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_pkd_item_packed_sync"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF TG_OP <> 'DELETE' THEN
    PERFORM public.recompute_alloc_packed(NEW.maintenance_db_id, NEW.pkg_instance_id);
  END IF;
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND
       (OLD.maintenance_db_id IS DISTINCT FROM NEW.maintenance_db_id
        OR OLD.pkg_instance_id IS DISTINCT FROM NEW.pkg_instance_id)) THEN
    PERFORM public.recompute_alloc_packed(OLD.maintenance_db_id, OLD.pkg_instance_id);
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."trg_pkd_item_packed_sync"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unpack_order_package"("op_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  UPDATE order_packages
  SET status = 'in_production',
      updated_at = NOW()
  WHERE id = op_id AND status = 'packed';
END;
$$;


ALTER FUNCTION "public"."unpack_order_package"("op_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unpause_task"("task_log_id" "uuid", "pause_duration_seconds" numeric DEFAULT NULL::numeric) RETURNS json
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$ 
DECLARE 
  result JSON; 
  current_pause NUMERIC;
BEGIN 
  -- If pause duration is provided, add it to existing pause duration
  IF pause_duration_seconds IS NOT NULL THEN
    SELECT COALESCE(pause_duration, 0) INTO current_pause
    FROM task_logs WHERE id = task_log_id;
    
    UPDATE task_logs 
    SET 
      pause_duration = current_pause + pause_duration_seconds,
      restart_time = NOW(),
      update_counter = COALESCE(update_counter, 0) + 1,
      updated_at = NOW()
    WHERE id = task_log_id;
  ELSE
    UPDATE task_logs 
    SET 
      restart_time = NOW(),
      update_counter = COALESCE(update_counter, 0) + 1,
      updated_at = NOW()
    WHERE id = task_log_id;
  END IF;
  
  -- Set all assignments for this task back to in_progress
  UPDATE task_assignments 
  SET task_status = 'in_progress'
  WHERE task_id = task_log_id;
  
  -- Return success
  result := json_build_object(
    'success', true,
    'message', 'Task resumed from pause',
    'restart_time', NOW()
  );
  
  RETURN result;
END; 
$$;


ALTER FUNCTION "public"."unpause_task"("task_log_id" "uuid", "pause_duration_seconds" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_app_settings_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_app_settings_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_packer_status_on_assignment"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$ BEGIN IF TG_OP = 'INSERT' THEN UPDATE public.profiles SET packer_status = 'busy', current_order_id = NEW.order_id, updated_at = NOW() WHERE id = NEW.packer_id; RETURN NEW; END IF; IF TG_OP = 'DELETE' THEN IF NOT EXISTS ( SELECT 1 FROM public.order_team_members otm JOIN public.orders o ON otm.order_id = o.id WHERE otm.packer_id = OLD.packer_id AND o.production_status IN ('pending', 'in_progress') ) THEN UPDATE public.profiles SET packer_status = 'available', current_order_id = NULL, updated_at = NOW() WHERE id = OLD.packer_id; END IF; RETURN OLD; END IF; RETURN NULL; END; $$;


ALTER FUNCTION "public"."update_packer_status_on_assignment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_packer_status_on_order_completion"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$ BEGIN IF NEW.production_status = 'completed' AND OLD.production_status != 'completed' THEN UPDATE public.profiles SET packer_status = 'available', current_order_id = NULL, updated_at = NOW() WHERE id IN ( SELECT packer_id FROM public.order_team_members WHERE order_id = NEW.id ); END IF; RETURN NEW; END; $$;


ALTER FUNCTION "public"."update_packer_status_on_order_completion"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_pending_material_additions_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_pending_material_additions_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_project_lead_with_status"("order_uuid" "uuid", "lead_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ BEGIN UPDATE public.orders SET project_lead_id = lead_id, updated_at = NOW() WHERE id = order_uuid; UPDATE public.orders SET production_status = 'in_progress', start_date = COALESCE(start_date, NOW()), updated_at = NOW() WHERE id = order_uuid AND production_status = 'pending' AND EXISTS ( SELECT 1 FROM public.order_team_members WHERE order_id = order_uuid ); END; $$;


ALTER FUNCTION "public"."update_project_lead_with_status"("order_uuid" "uuid", "lead_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;


ALTER FUNCTION "public"."update_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_order_item_allocation"("p_order_id" "uuid", "p_items_db_id" "uuid", "p_destination_id" "uuid", "p_expected" numeric, "p_is_standard_box" boolean) RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE v_id uuid; v_old numeric := 0;
BEGIN
  IF p_expected IS NULL OR p_expected < 0 THEN RAISE EXCEPTION 'expected_qty must be >= 0'; END IF;
  IF p_expected <> floor(p_expected) THEN RAISE EXCEPTION 'expected_qty must be a whole number'; END IF;
  IF p_order_id IS NULL OR p_items_db_id IS NULL OR p_destination_id IS NULL THEN
    RAISE EXCEPTION 'order, item and destination are required';
  END IF;

  SELECT id, expected_qty INTO v_id, v_old
  FROM order_item_allocation
  WHERE order_id = p_order_id AND items_db_id = p_items_db_id AND destination_id = p_destination_id;

  IF v_id IS NULL THEN
    INSERT INTO order_item_allocation (order_id, items_db_id, destination_id, expected_qty, packed_qty, is_standard_box)
    VALUES (p_order_id, p_items_db_id, p_destination_id, p_expected, 0, COALESCE(p_is_standard_box, false))
    RETURNING id INTO v_id;
    v_old := 0;
  ELSE
    UPDATE order_item_allocation
    SET expected_qty = p_expected,
        is_standard_box = COALESCE(p_is_standard_box, is_standard_box),
        updated_at = now()
    WHERE id = v_id;
  END IF;

  UPDATE items_db
  SET expected_qty = GREATEST(0, COALESCE(expected_qty, 0) + (p_expected - COALESCE(v_old, 0))),
      updated_at = now()
  WHERE id = p_items_db_id;

  RETURN v_id;
END; $$;


ALTER FUNCTION "public"."upsert_order_item_allocation"("p_order_id" "uuid", "p_items_db_id" "uuid", "p_destination_id" "uuid", "p_expected" numeric, "p_is_standard_box" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_assigned_to_order"("order_uuid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ BEGIN RETURN EXISTS ( SELECT 1 FROM public.order_team_members WHERE order_id = order_uuid AND packer_id = auth.uid() ); END; $$;


ALTER FUNCTION "public"."user_assigned_to_order"("order_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_has_permission"("permission_name" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN (
    SELECT CASE permission_name
      WHEN 'can_block_users' THEN r.can_block_users
      WHEN 'can_unblock_users' THEN r.can_unblock_users
      WHEN 'can_ban_users' THEN r.can_ban_users
      WHEN 'can_reset_passwords' THEN r.can_reset_passwords
      WHEN 'can_delete_profiles' THEN r.can_delete_profiles
      WHEN 'can_manage_roles' THEN r.can_manage_roles
      ELSE FALSE
    END
    FROM public.profiles p
    JOIN public.roles r ON p.role_id = r.id
    WHERE p.id = auth.uid()
    AND p.status = 'active'
  );
END;
$$;


ALTER FUNCTION "public"."user_has_permission"("permission_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_box_completion"("op_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  validation_result jsonb;
  materials_valid boolean;
  tasks_valid boolean;
  materials_msg text;
  tasks_msg text;
  unused_materials_count int;
  excess_materials_count int;
  active_tasks_count int;
  -- Only validate against currently active material types;
  -- rows with legacy/unknown types (e.g. from old app versions) are ignored.
  active_material_types text[] := ARRAY['Accessories', 'Securing', 'Gas Packing', 'Vacuum Packing'];
BEGIN
  -- Check materials: All must be used OR have no quantity (quantity_used null/0)
  SELECT COUNT(*) INTO unused_materials_count
  FROM order_package_materials
  WHERE order_package_id = op_id
    AND is_final = true
    AND item_used = false
    AND (quantity_used IS NULL OR quantity_used = 0)
    AND material_type::text = ANY(active_material_types);

  -- Check for excess materials (quantity_used < quantity when item was not fully used)
  SELECT COUNT(*) INTO excess_materials_count
  FROM order_package_materials
  WHERE order_package_id = op_id
    AND is_final = true
    AND item_used = false
    AND quantity_used IS NOT NULL
    AND quantity_used > 0
    AND quantity_used < quantity
    AND material_type::text = ANY(active_material_types);

  materials_valid := (unused_materials_count = 0);

  IF NOT materials_valid THEN
    IF excess_materials_count > 0 THEN
      materials_msg := format('%s material(s) have excess quantities that need to be removed or marked as used', unused_materials_count + excess_materials_count);
    ELSE
      materials_msg := format('%s material(s) are not marked as used or have no quantity recorded', unused_materials_count);
    END IF;
  ELSE
    materials_msg := 'All materials validated';
  END IF;

  -- Check tasks: All tasks related to this box must be completed (have end_time)
  SELECT COUNT(*) INTO active_tasks_count
  FROM task_packages tp
  JOIN task_logs tl ON tp.task_log_id = tl.id
  WHERE tp.order_package_id = op_id
    AND tl.end_time IS NULL;

  tasks_valid := (active_tasks_count = 0);

  IF NOT tasks_valid THEN
    tasks_msg := format('%s active task(s) must be completed before marking box as complete', active_tasks_count);
  ELSE
    tasks_msg := 'All tasks completed';
  END IF;

  -- Build result
  validation_result := jsonb_build_object(
    'valid', materials_valid AND tasks_valid,
    'materials_valid', materials_valid,
    'materials_message', materials_msg,
    'tasks_valid', tasks_valid,
    'tasks_message', tasks_msg
  );

  RETURN validation_result;
END;
$$;


ALTER FUNCTION "public"."validate_box_completion"("op_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."allocation_increase_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "items_db_id" "uuid" NOT NULL,
    "destination_id" "uuid" NOT NULL,
    "requested_delta" numeric NOT NULL,
    "reason" "text",
    "requested_by" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "admin_notes" "text",
    "order_package_context" "uuid",
    CONSTRAINT "allocation_increase_requests_requested_delta_check" CHECK (("requested_delta" > (0)::numeric))
);


ALTER TABLE "public"."allocation_increase_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "key" "text" NOT NULL,
    "value" "jsonb" NOT NULL,
    "description" "text",
    "category" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."app_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."attendance_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "packer_id" "uuid" NOT NULL,
    "log_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "shift_period" "text" NOT NULL,
    "status" "text" DEFAULT 'present'::"text" NOT NULL,
    "start_time" timestamp with time zone,
    "end_time" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "toolbox_briefing_completed" boolean DEFAULT false,
    "is_project_start" boolean DEFAULT false,
    CONSTRAINT "attendance_logs_shift_period_check" CHECK (("shift_period" = ANY (ARRAY['morning'::"text", 'afternoon'::"text", 'full_day'::"text"]))),
    CONSTRAINT "attendance_logs_status_check" CHECK (("status" = ANY (ARRAY['present'::"text", 'absent'::"text"])))
);


ALTER TABLE "public"."attendance_logs" OWNER TO "postgres";


COMMENT ON COLUMN "public"."attendance_logs"."toolbox_briefing_completed" IS 'Mandatory safety briefing completion status';



COMMENT ON COLUMN "public"."attendance_logs"."is_project_start" IS 'Marks the first day this packer worked on this project';



CREATE TABLE IF NOT EXISTS "public"."audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "column_name" "text",
    "old_value" "jsonb",
    "new_value" "jsonb",
    "changed_by" "uuid",
    "change_time" timestamp with time zone DEFAULT "now"(),
    "action_type" "text" NOT NULL,
    "is_critical_alert" boolean DEFAULT false,
    "notes" "text",
    "order_id" "uuid",
    "order_package_id" "uuid",
    CONSTRAINT "audit_log_action_type_check" CHECK (("action_type" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text", 'ALERT'::"text", 'PASSWORD_RESET'::"text", 'BLOCK_USER'::"text", 'UNBLOCK_USER'::"text", 'BAN_USER'::"text", 'ROLE_CHANGE'::"text", 'PROFILE_DELETE'::"text"])))
);


ALTER TABLE "public"."audit_log" OWNER TO "postgres";


COMMENT ON COLUMN "public"."audit_log"."order_package_id" IS 'Links audit entries to specific order packages for better filtering';



CREATE TABLE IF NOT EXISTS "public"."beam" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "quantity" numeric,
    "type" "uuid",
    "width" numeric,
    "thickness" numeric,
    "space" numeric
);


ALTER TABLE "public"."beam" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."box_type" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "code" "text"
);


ALTER TABLE "public"."box_type" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."category_order_map" (
    "category_id" "uuid",
    "order_id" "uuid"
);


ALTER TABLE "public"."category_order_map" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."category_tag_map" (
    "category_id" "uuid" NOT NULL,
    "tag_id" "uuid" NOT NULL,
    "tag_order" integer DEFAULT 1 NOT NULL
);


ALTER TABLE "public"."category_tag_map" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_order" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_report_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "customer_order_ref" "text",
    "quotation_ref" "text",
    "delivery_note_ref" "text",
    "delivery_date" "date",
    "sequence_order" integer DEFAULT 1
);


ALTER TABLE "public"."client_order" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_portal_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "portal_slug" "text" NOT NULL,
    "is_active" boolean DEFAULT false NOT NULL,
    "requires_auth" boolean DEFAULT true NOT NULL,
    "qr_logo_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "show_qr_logo" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."client_portal_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_quality_control" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_report_id" "uuid" NOT NULL,
    "entity_type" "text" NOT NULL,
    "display_name" "text",
    "checked_by" "text",
    "title" "text",
    "signature_url" "text",
    "checked_date" "date",
    "sequence_order" integer DEFAULT 1,
    CONSTRAINT "client_quality_control_entity_type_check" CHECK (("entity_type" = ANY (ARRAY['ipac_valsem'::"text", 'customer'::"text"])))
);


ALTER TABLE "public"."client_quality_control" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_report" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "report_name" "text" NOT NULL,
    "report_number" "text",
    "report_types" "text"[] DEFAULT '{standard_report}'::"text"[] NOT NULL,
    "report_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "date_from" "date",
    "date_to" "date",
    "period_type" "text" DEFAULT 'custom'::"text" NOT NULL,
    "date_filter_mode" "text" DEFAULT 'packed_at'::"text" NOT NULL,
    "detail_level" "text" DEFAULT 'detailed'::"text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "client_id" "uuid",
    "project_reference" "text",
    "display_settings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "base_pkg_details_settings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "company_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "filter_criteria" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "included_statuses" "text"[] DEFAULT ARRAY['packed'::"text"] NOT NULL,
    "transport_modes" "text"[],
    "final_destination_country" "text",
    "orientation" "text" DEFAULT 'portrait'::"text",
    "template_id" "uuid",
    "batch_id" "uuid",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "client_report_date_filter_mode_check" CHECK (("date_filter_mode" = ANY (ARRAY['packed_at'::"text", 'order_created_at'::"text"]))),
    CONSTRAINT "client_report_detail_level_check" CHECK (("detail_level" = ANY (ARRAY['detailed'::"text", 'summary'::"text"]))),
    CONSTRAINT "client_report_orientation_check" CHECK (("orientation" = ANY (ARRAY['portrait'::"text", 'landscape'::"text"]))),
    CONSTRAINT "client_report_period_type_check" CHECK (("period_type" = ANY (ARRAY['daily'::"text", 'weekly'::"text", 'monthly'::"text", 'custom'::"text"]))),
    CONSTRAINT "client_report_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'finalized'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."client_report" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_report_collaborators" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_report_id" "uuid" NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "can_edit" boolean DEFAULT true NOT NULL,
    "added_by" "uuid",
    "added_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."client_report_collaborators" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_report_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_report_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL
);


ALTER TABLE "public"."client_report_orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_shipment" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_report_id" "uuid" NOT NULL,
    "consignee" "text",
    "shipping_date" "date",
    "address_1" "text",
    "address_2" "text",
    "address_3" "text",
    "post_code" "text",
    "city" "text",
    "country" "text",
    "contact" "text",
    "phone" "text",
    "email" "text"
);


ALTER TABLE "public"."client_shipment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clients" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "contact_person" "text",
    "email" "text",
    "phone" "text",
    "address" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "portal_settings_id" "uuid",
    "trn" "text",
    "address_line_1" "text",
    "address_line_2" "text",
    "city" "text",
    "country" "text",
    "post_code" "text",
    "address_line_3" "text"
);


ALTER TABLE "public"."clients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."destinations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text",
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."destinations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."import_taqa3_catalog" (
    "item_num" "text" NOT NULL,
    "qty" integer NOT NULL,
    "warehouse_location" "text",
    "length" numeric,
    "width" numeric,
    "height" numeric,
    "net_weight" numeric,
    "packing_type" "text",
    "ipac_comments" "text"
);


ALTER TABLE "public"."import_taqa3_catalog" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."instance_c_report_map" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_report_id" "uuid" NOT NULL,
    "package_instance_id" "uuid" NOT NULL,
    "pkg_details_settings" "jsonb",
    "group_label" "text",
    "group_order" integer DEFAULT 1,
    "sequence_order" integer DEFAULT 1
);


ALTER TABLE "public"."instance_c_report_map" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."items_db" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "reference" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "ipac_comments" "text",
    "expected_qty" integer DEFAULT 0 NOT NULL,
    "category_id" "uuid",
    "item_num" "text",
    "description" "text",
    "length" numeric,
    "width" numeric,
    "height" numeric,
    "net_weight" numeric,
    "warehouse_location" "text",
    "packed_qty" numeric DEFAULT 0,
    CONSTRAINT "maintenance_db_quantity_check" CHECK (("expected_qty" >= 0))
);


ALTER TABLE "public"."items_db" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."maintenance_task_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "maintenance_task_log_id" "uuid" NOT NULL,
    "packer_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."maintenance_task_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."maintenance_task_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_package_id" "uuid" NOT NULL,
    "task_id" "uuid" NOT NULL,
    "sequence_order" integer NOT NULL,
    "start_time" timestamp with time zone,
    "end_time" timestamp with time zone,
    "duration_minutes" integer,
    "task_status" "public"."maintenance_task_status" DEFAULT 'pending'::"public"."maintenance_task_status" NOT NULL,
    "category" "public"."maintenance_task_category" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."maintenance_task_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."material_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "unit_id" "uuid",
    "requested_by" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"(),
    "admin_notes" "text",
    "order_package_context" "uuid"
);


ALTER TABLE "public"."material_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."material_tags" (
    "material_id" "uuid" NOT NULL,
    "tag_id" "uuid" NOT NULL
);


ALTER TABLE "public"."material_tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."material_variant_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "material_id" "uuid",
    "variant_name" "text" NOT NULL,
    "attributes" "jsonb",
    "description" "text",
    "unit_id" "uuid",
    "length" numeric,
    "width" numeric,
    "thickness" numeric,
    "weight_per_unit" numeric,
    "requested_by" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"(),
    "admin_notes" "text",
    "order_package_context" "uuid",
    "material_request_id" "uuid",
    CONSTRAINT "chk_mvr_material_source" CHECK (((("material_id" IS NOT NULL) AND ("material_request_id" IS NULL)) OR (("material_id" IS NULL) AND ("material_request_id" IS NOT NULL))))
);


ALTER TABLE "public"."material_variant_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."material_variant_tags" (
    "material_variant_id" "uuid" NOT NULL,
    "tag_id" "uuid" NOT NULL
);


ALTER TABLE "public"."material_variant_tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."material_variants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "material_id" "uuid" NOT NULL,
    "variant_name" "text" NOT NULL,
    "attributes" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "description" "text",
    "unit_id" "uuid",
    "length" numeric,
    "width" numeric,
    "thickness" numeric,
    "weight_per_unit" numeric,
    "pending_approval" boolean DEFAULT false,
    "approval_status" "text" DEFAULT 'approved'::"text",
    "requested_by" "uuid",
    "requested_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "admin_notes" "text",
    "order_package_context" "uuid",
    CONSTRAINT "material_variants_approval_status_check" CHECK (("approval_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."material_variants" OWNER TO "postgres";


COMMENT ON COLUMN "public"."material_variants"."pending_approval" IS 'True if this variant was added by a packer and needs admin review';



COMMENT ON COLUMN "public"."material_variants"."order_package_context" IS 'The order package the packer was working on when they added this variant';



CREATE TABLE IF NOT EXISTS "public"."materials" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "unit_id" "uuid",
    "pending_approval" boolean DEFAULT false,
    "approval_status" "text" DEFAULT 'approved'::"text",
    "requested_by" "uuid",
    "requested_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "admin_notes" "text",
    "order_package_context" "uuid",
    CONSTRAINT "materials_approval_status_check" CHECK (("approval_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."materials" OWNER TO "postgres";


COMMENT ON COLUMN "public"."materials"."pending_approval" IS 'True if this material was added by a packer and needs admin review';



COMMENT ON COLUMN "public"."materials"."order_package_context" IS 'The order package the packer was working on when they added this material';



CREATE TABLE IF NOT EXISTS "public"."media" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "image_url" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "order_package_id" "uuid" NOT NULL,
    "designation" "public"."MediaCategory",
    "maintenance_task_log_id" "uuid",
    "order_pkg_instance_id" "uuid",
    "pkd_item_id" "uuid",
    "package_item_id" "uuid",
    "task_log_id" "uuid"
);


ALTER TABLE "public"."media" OWNER TO "postgres";


COMMENT ON COLUMN "public"."media"."designation" IS 'what category does this image/video belong to?';



COMMENT ON COLUMN "public"."media"."order_pkg_instance_id" IS 'Links to a specific physical box instance';



COMMENT ON COLUMN "public"."media"."pkd_item_id" IS 'Links to a specific item within a maintenance box instance';



COMMENT ON COLUMN "public"."media"."package_item_id" IS 'Links to a specific item within a standard package';



COMMENT ON COLUMN "public"."media"."task_log_id" IS 'Links to a standard order task log';



CREATE TABLE IF NOT EXISTS "public"."order_item_allocation" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "items_db_id" "uuid" NOT NULL,
    "destination_id" "uuid" NOT NULL,
    "expected_qty" numeric DEFAULT 0 NOT NULL,
    "packed_qty" numeric DEFAULT 0 NOT NULL,
    "packing_type" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "category_tag" "text",
    "is_standard_box" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."order_item_allocation" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_package_materials" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_package_id" "uuid" NOT NULL,
    "material_variant_id" "uuid",
    "material_type" "public"."material_type" NOT NULL,
    "is_final" boolean DEFAULT false NOT NULL,
    "quantity" numeric NOT NULL,
    "unit_id" "uuid" NOT NULL,
    "length" numeric,
    "width" numeric,
    "height" numeric,
    "comment" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "item_used" boolean DEFAULT false NOT NULL,
    "original" "uuid",
    "quantity_used" numeric,
    "variant_request_id" "uuid",
    "thickness" real,
    CONSTRAINT "chk_opm_variant_source" CHECK (((("material_variant_id" IS NOT NULL) AND ("variant_request_id" IS NULL)) OR (("material_variant_id" IS NULL) AND ("variant_request_id" IS NOT NULL)))),
    CONSTRAINT "order_package_materials_quantity_check" CHECK (("quantity" >= (0)::numeric))
);


ALTER TABLE "public"."order_package_materials" OWNER TO "postgres";


COMMENT ON COLUMN "public"."order_package_materials"."item_used" IS 'did the packer use this item?';



CREATE TABLE IF NOT EXISTS "public"."order_package_securing" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_package_id" "uuid" NOT NULL,
    "securing_template_id" "uuid" NOT NULL,
    "securing_side" "public"."securing_side" NOT NULL,
    "is_final" boolean NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."order_package_securing" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_package_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_package_id" "uuid" NOT NULL,
    "service_id" "uuid" NOT NULL,
    "is_final" boolean DEFAULT false NOT NULL,
    "result" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."order_package_services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."order_packages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "package_number" integer NOT NULL,
    "description" "text",
    "status" "text" DEFAULT 'design'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "original_pkg_info" "uuid",
    "final_pkg_info" "uuid",
    "comments" "jsonb" DEFAULT '[]'::"jsonb",
    "maintenance_package_type" "public"."maintenance_package_type",
    "reference" "text",
    CONSTRAINT "order_packages_status_check" CHECK (("status" = ANY (ARRAY['design'::"text", 'approved'::"text", 'in_production'::"text", 'packed'::"text", 'delivered'::"text"])))
);


ALTER TABLE "public"."order_packages" OWNER TO "postgres";


COMMENT ON COLUMN "public"."order_packages"."comments" IS 'Array of comment objects with structure: [{"text": "comment text", "created_by": "user_id", "created_at": "timestamp", "packer_name": "full name"}]';



COMMENT ON COLUMN "public"."order_packages"."reference" IS 'customer reference';



CREATE TABLE IF NOT EXISTS "public"."order_pkg_instance" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_pkg_overview_id" "uuid" NOT NULL,
    "order_package_id" "uuid" NOT NULL,
    "instance_number" integer NOT NULL,
    "status" "text" DEFAULT 'approved'::"text" NOT NULL,
    "packed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ipac_reference" "text",
    "client_reference" "text",
    "destination" "text",
    "tag" character varying(255),
    "category_id" "uuid",
    CONSTRAINT "order_pkg_instance_number_check" CHECK (("instance_number" > 0)),
    CONSTRAINT "order_pkg_instance_status_check" CHECK (("status" = ANY (ARRAY['design'::"text", 'approved'::"text", 'in_production'::"text", 'packed'::"text"])))
);


ALTER TABLE "public"."order_pkg_instance" OWNER TO "postgres";


COMMENT ON TABLE "public"."order_pkg_instance" IS 'Physical box instances. Supports per-box identity and copy-on-write when one box diverges.';



COMMENT ON COLUMN "public"."order_pkg_instance"."instance_number" IS 'Per-overview sequence number for physical boxes (1..quantity).';



CREATE TABLE IF NOT EXISTS "public"."order_pkg_overview" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "pkg_number" integer NOT NULL,
    "status" "text" DEFAULT 'approved'::"text" NOT NULL,
    "quantity" integer DEFAULT 1 NOT NULL,
    "quantity_packed" integer DEFAULT 0 NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "order_pkg_overview_quantity_check" CHECK (("quantity" > 0)),
    CONSTRAINT "order_pkg_overview_quantity_packed_check" CHECK ((("quantity_packed" >= 0) AND ("quantity_packed" <= "quantity"))),
    CONSTRAINT "order_pkg_overview_status_check" CHECK (("status" = ANY (ARRAY['design'::"text", 'approved'::"text", 'in_production'::"text", 'packed'::"text"])))
);


ALTER TABLE "public"."order_pkg_overview" OWNER TO "postgres";


COMMENT ON TABLE "public"."order_pkg_overview" IS 'Tab-level grouping. One row can represent many physical boxes of same template.';



COMMENT ON COLUMN "public"."order_pkg_overview"."pkg_number" IS 'Human-facing package/tab number within an order (1..N).';



CREATE TABLE IF NOT EXISTS "public"."order_team_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "packer_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_team_lead" boolean DEFAULT false
);


ALTER TABLE "public"."order_team_members" OWNER TO "postgres";


COMMENT ON COLUMN "public"."order_team_members"."is_team_lead" IS 'Team lead status for this packer on this specific order. Multiple leads are supported per order.';



CREATE TABLE IF NOT EXISTS "public"."orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "order_name" "text" NOT NULL,
    "description" "text",
    "commercial_status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "created_by" "uuid",
    "total_estimated_cost" numeric,
    "total_actual_cost" numeric,
    "production_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "start_date" timestamp with time zone,
    "completion_date" timestamp with time zone,
    "total_transportation_cost" numeric DEFAULT 0.0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "project_lead_id" "uuid",
    "project_type" "public"."project_type" DEFAULT 'standard'::"public"."project_type" NOT NULL,
    "reference" "text",
    CONSTRAINT "orders_commercial_status_check" CHECK (("commercial_status" = ANY (ARRAY['draft'::"text", 'quoted'::"text", 'approved'::"text", 'invoiced'::"text", 'paid'::"text"]))),
    CONSTRAINT "orders_production_status_check" CHECK (("production_status" = ANY (ARRAY['pending'::"text", 'in_progress'::"text", 'completed'::"text", 'on_hold'::"text"])))
);


ALTER TABLE "public"."orders" OWNER TO "postgres";


COMMENT ON COLUMN "public"."orders"."project_lead_id" IS 'Packer assigned as project lead (chosen during team assignment)';



COMMENT ON COLUMN "public"."orders"."reference" IS 'customer reference';



CREATE TABLE IF NOT EXISTS "public"."package_info" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "internal_length" numeric,
    "internal_width" numeric,
    "internal_height" numeric,
    "external_length" numeric,
    "external_width" numeric,
    "external_height" numeric,
    "center_of_gravity" boolean,
    "quantity" integer,
    "packing_type_id" "uuid",
    "tare" numeric,
    "net_weight" numeric,
    "gross_weight" numeric,
    "boxes_completed" integer DEFAULT 0 NOT NULL,
    "box_type_id" "uuid",
    "sei_category" smallint,
    "sei_protection" smallint
);


ALTER TABLE "public"."package_info" OWNER TO "postgres";


COMMENT ON COLUMN "public"."package_info"."quantity" IS 'Legacy quantity source for old flow. New flow uses order_pkg_overview.quantity.';



COMMENT ON COLUMN "public"."package_info"."boxes_completed" IS 'the amount of boxes completed for this order package';



CREATE TABLE IF NOT EXISTS "public"."package_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_package_id" "uuid" NOT NULL,
    "quantity" integer,
    "designation" character varying,
    "length" numeric,
    "width" numeric,
    "height" numeric,
    "reference" "text",
    "net_weight" numeric,
    "items_db_id" "uuid"
);


ALTER TABLE "public"."package_items" OWNER TO "postgres";


COMMENT ON COLUMN "public"."package_items"."length" IS 'length of item';



COMMENT ON COLUMN "public"."package_items"."width" IS 'width of item';



COMMENT ON COLUMN "public"."package_items"."height" IS 'height of item';



COMMENT ON COLUMN "public"."package_items"."reference" IS 'customer reference';



CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "username" "text",
    "phone_number" "text",
    "role_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "avatar_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "packer_status" "text" DEFAULT 'available'::"text",
    "current_order_id" "uuid",
    "client_id" "uuid",
    CONSTRAINT "profiles_packer_status_check" CHECK (("packer_status" = ANY (ARRAY['available'::"text", 'busy'::"text", 'unavailable'::"text"]))),
    CONSTRAINT "profiles_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'blocked'::"text", 'banned'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."packer_status" IS 'Tracks if packer is available for new assignments, busy with current order, or unavailable';



COMMENT ON COLUMN "public"."profiles"."current_order_id" IS 'References the order the packer is currently working on when busy';



CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "can_block_users" boolean DEFAULT false,
    "can_unblock_users" boolean DEFAULT false,
    "can_ban_users" boolean DEFAULT false,
    "can_reset_passwords" boolean DEFAULT false,
    "can_delete_profiles" boolean DEFAULT false,
    "can_manage_roles" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."packer_availability_status" AS
 SELECT "p"."id",
    "p"."full_name",
    "p"."username",
    "p"."packer_status",
    "p"."current_order_id",
    "o"."order_name" AS "current_order_name",
        CASE
            WHEN ("p"."packer_status" = 'available'::"text") THEN 'Available for assignment'::"text"
            WHEN ("p"."packer_status" = 'busy'::"text") THEN "concat"('Working on: ', COALESCE("o"."order_name", 'Unknown Order'::"text"))
            WHEN ("p"."packer_status" = 'unavailable'::"text") THEN 'Not available'::"text"
            ELSE 'Status unknown'::"text"
        END AS "status_description"
   FROM (("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
     LEFT JOIN "public"."orders" "o" ON (("p"."current_order_id" = "o"."id")))
  WHERE (("r"."name" = 'packer'::"text") AND ("p"."status" = 'active'::"text"));


ALTER VIEW "public"."packer_availability_status" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."packer_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "packer_id" "uuid",
    "order_id" "uuid",
    "order_name" "text",
    "client_name" "text",
    "project_lead_name" "text",
    "team_selected" boolean DEFAULT false,
    "attendance_completed" boolean DEFAULT false,
    "packaging_started" boolean DEFAULT false,
    "session_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."packer_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."packing_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "includes_contact" boolean DEFAULT false,
    "includes_waterproofing" boolean DEFAULT false,
    "includes_gas_protection" boolean DEFAULT false,
    "includes_vibration_protection" boolean DEFAULT false,
    "base_material_type" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "includes_vacuum_protection" boolean DEFAULT false
);


ALTER TABLE "public"."packing_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pkd_item" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "maintenance_db_id" "uuid",
    "quantity" numeric DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "pkg_instance_id" "uuid" NOT NULL,
    "is_confirmed" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."pkd_item" OWNER TO "postgres";


COMMENT ON COLUMN "public"."pkd_item"."pkg_instance_id" IS 'Required target in grouped-box flow; references public.order_pkg_instance(id).';



CREATE TABLE IF NOT EXISTS "public"."pkg_category" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "label" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."pkg_category" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_tags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "client_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "abbreviation" "text"
);


ALTER TABLE "public"."project_tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."qr_codes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "token" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(8), 'hex'::"text") NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "qr_codes_entity_type_check" CHECK (("entity_type" = ANY (ARRAY['package'::"text", 'item'::"text", 'pkd_item'::"text"])))
);


ALTER TABLE "public"."qr_codes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."report_batch" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_name" "text" NOT NULL,
    "split_by" "text",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "total_reports" integer DEFAULT 0
);


ALTER TABLE "public"."report_batch" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."report_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."report_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."report_template_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_name" "text" NOT NULL,
    "description" "text",
    "display_settings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "pkg_details_settings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "orientation" "text" DEFAULT 'portrait'::"text",
    "is_public" boolean DEFAULT false NOT NULL,
    "client_id" "uuid",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "report_template_settings_orientation_check" CHECK (("orientation" = ANY (ARRAY['portrait'::"text", 'landscape'::"text"])))
);


ALTER TABLE "public"."report_template_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."request_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_type" "public"."request_type" NOT NULL,
    "action" "public"."request_action" NOT NULL,
    "request_snapshot" "jsonb" NOT NULL,
    "requested_by" "uuid",
    "requested_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "admin_notes" "text",
    "resulting_id" "uuid",
    "order_package_context" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."request_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."securing_template" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "quantity" integer,
    "type_id" "uuid",
    "thickness" numeric,
    "horizontal_bar" "uuid",
    "vertical_bar" "uuid",
    "skids" "uuid"
);


ALTER TABLE "public"."securing_template" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sei_categories" (
    "id" smallint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "code" smallint,
    "name" "text",
    "description" "text"
);


ALTER TABLE "public"."sei_categories" OWNER TO "postgres";


ALTER TABLE "public"."sei_categories" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."sei_categories_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."sei_protection" (
    "id" smallint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "code" "text",
    "name" "text",
    "description" "text"
);


ALTER TABLE "public"."sei_protection" OWNER TO "postgres";


ALTER TABLE "public"."sei_protection" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."sei_protection_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service" "text" NOT NULL,
    "tag_id" "uuid" NOT NULL,
    "ui_code" "text"
);


ALTER TABLE "public"."services" OWNER TO "postgres";


COMMENT ON COLUMN "public"."services"."ui_code" IS 'since electronic humidity and temperature indicator requires two results and oxygen needs one, we will use the ui_code to have the app require two values for humidity/temperature, and one for oxygen and more if needed, and since we use humidity/temperature for both vacuum/gas this couples the code into one making it more efficient';



CREATE TABLE IF NOT EXISTS "public"."signatures" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "label" "text" DEFAULT ''::"text" NOT NULL,
    "image_path" "text" NOT NULL,
    "is_public" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."signatures" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."supplier_email_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "supplier_id" "uuid",
    "supplier_name" "text",
    "supplier_email" "text" NOT NULL,
    "direction" "text" NOT NULL,
    "reason" "text",
    "subject" "text" NOT NULL,
    "body_text" "text" NOT NULL,
    "resend_email_id" "text",
    "in_reply_to_resend_email_id" "text",
    "status" "text",
    "related_variant_ids" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "supplier_email_messages_direction_check" CHECK (("direction" = ANY (ARRAY['outbound'::"text", 'inbound'::"text"])))
);


ALTER TABLE "public"."supplier_email_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."supplier_pricing" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "material_variant_id" "uuid" NOT NULL,
    "price" numeric DEFAULT '0'::numeric NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "supplier_id" "uuid" NOT NULL,
    "price_per_unit" numeric DEFAULT '0'::numeric NOT NULL,
    "supplier_quantity" numeric DEFAULT '0'::numeric NOT NULL,
    "suppliers_reference" "text",
    "pending_approval" boolean DEFAULT false,
    "approval_status" "text" DEFAULT 'approved'::"text",
    "requested_by" "uuid",
    "requested_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "admin_notes" "text",
    "order_package_context" "uuid",
    CONSTRAINT "supplier_pricing_approval_status_check" CHECK (("approval_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."supplier_pricing" OWNER TO "postgres";


COMMENT ON COLUMN "public"."supplier_pricing"."supplier_quantity" IS 'the total amount of a product received from the supplier';



COMMENT ON COLUMN "public"."supplier_pricing"."pending_approval" IS 'True if this pricing was added by a packer and needs admin review';



COMMENT ON COLUMN "public"."supplier_pricing"."order_package_context" IS 'The order package the packer was working on when they added this pricing';



CREATE TABLE IF NOT EXISTS "public"."supplier_pricing_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "material_variant_id" "uuid",
    "supplier_id" "uuid" NOT NULL,
    "price" numeric DEFAULT '0'::numeric NOT NULL,
    "price_per_unit" numeric DEFAULT '0'::numeric NOT NULL,
    "supplier_quantity" numeric DEFAULT '0'::numeric NOT NULL,
    "suppliers_reference" "text",
    "requested_by" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"(),
    "admin_notes" "text",
    "order_package_context" "uuid",
    "variant_request_id" "uuid",
    CONSTRAINT "chk_spr_variant_source" CHECK (((("material_variant_id" IS NOT NULL) AND ("variant_request_id" IS NULL)) OR (("material_variant_id" IS NULL) AND ("variant_request_id" IS NOT NULL))))
);


ALTER TABLE "public"."supplier_pricing_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."suppliers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "contact_person" "text",
    "email" "text",
    "phone" "text",
    "address" "text",
    "other_info" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."suppliers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "packer_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "task_status" "public"."task_status" DEFAULT 'in_progress'::"public"."task_status"
);


ALTER TABLE "public"."task_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "start_time" timestamp with time zone NOT NULL,
    "end_time" timestamp with time zone,
    "duration_minutes" numeric,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "task_id" "uuid",
    "pause_duration" numeric,
    "update_counter" integer,
    "restart_time" timestamp with time zone
);


ALTER TABLE "public"."task_logs" OWNER TO "postgres";


COMMENT ON COLUMN "public"."task_logs"."restart_time" IS 'the restart time of the task if the packer wants to continue a task that was marked completed, if the packer restarted the task more than once the time here will be of the lastest task restart, the use of this column is to calculate the duration of the task';



CREATE TABLE IF NOT EXISTS "public"."task_packages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_log_id" "uuid",
    "order_package_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."task_packages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tasks" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."task_status_view" AS
 SELECT "tl"."id" AS "task_log_id",
    "t"."name" AS "task_name",
    "t"."description" AS "task_description",
    "tl"."start_time",
    "tl"."end_time",
    "tl"."restart_time",
    "tl"."duration_minutes",
    "tl"."pause_duration",
    "tl"."update_counter",
    "tl"."notes",
        CASE
            WHEN ("tl"."end_time" IS NOT NULL) THEN 'completed'::"text"
            WHEN (EXISTS ( SELECT 1
               FROM "public"."task_assignments"
              WHERE (("task_assignments"."task_id" = "tl"."id") AND ("task_assignments"."task_status" = 'paused'::"public"."task_status")))) THEN 'paused'::"text"
            WHEN (EXISTS ( SELECT 1
               FROM "public"."task_assignments"
              WHERE (("task_assignments"."task_id" = "tl"."id") AND ("task_assignments"."task_status" = 'in_progress'::"public"."task_status")))) THEN 'in_progress'::"text"
            ELSE 'unknown'::"text"
        END AS "overall_status",
    ( SELECT "json_agg"("json_build_object"('packer_id', "ta"."packer_id", 'full_name', "p"."full_name", 'status', "ta"."task_status")) AS "json_agg"
           FROM ("public"."task_assignments" "ta"
             JOIN "public"."profiles" "p" ON (("ta"."packer_id" = "p"."id")))
          WHERE ("ta"."task_id" = "tl"."id")) AS "assigned_packers",
    ( SELECT "json_agg"("json_build_object"('order_package_id', "tp"."order_package_id", 'package_number', "op"."package_number")) AS "json_agg"
           FROM ("public"."task_packages" "tp"
             JOIN "public"."order_packages" "op" ON (("tp"."order_package_id" = "op"."id")))
          WHERE ("tp"."task_log_id" = "tl"."id")) AS "linked_packages"
   FROM ("public"."task_logs" "tl"
     JOIN "public"."tasks" "t" ON (("tl"."task_id" = "t"."id")))
  ORDER BY "tl"."created_at" DESC;


ALTER VIEW "public"."task_status_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."temporary_privileges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "granted_role_id" "uuid" NOT NULL,
    "granted_by" "uuid" NOT NULL,
    "reason" "text",
    "granted_at" timestamp with time zone DEFAULT "now"(),
    "expires_at" timestamp with time zone NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."temporary_privileges" OWNER TO "postgres";


COMMENT ON TABLE "public"."temporary_privileges" IS 'Stores temporary role privileges granted to users';



CREATE TABLE IF NOT EXISTS "public"."transportation" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "vehicle_type" "text",
    "transport_date" "date" NOT NULL,
    "distance_km" numeric,
    "cost_per_unit" numeric,
    "unit_id" "uuid",
    "total_cost" numeric NOT NULL,
    "notes" "text",
    "recorded_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."transportation" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."units_of_measure" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."units_of_measure" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."user_effective_permissions" AS
 SELECT "p"."id",
    "p"."full_name",
    "p"."username",
    "p"."status",
    "p"."packer_status",
    "r"."name" AS "base_role",
    "r"."can_block_users" AS "base_can_block_users",
    "r"."can_unblock_users" AS "base_can_unblock_users",
    "r"."can_ban_users" AS "base_can_ban_users",
    "r"."can_reset_passwords" AS "base_can_reset_passwords",
    "r"."can_delete_profiles" AS "base_can_delete_profiles",
    "r"."can_manage_roles" AS "base_can_manage_roles",
    (COALESCE("r"."can_block_users", false) OR COALESCE("bool_or"("tr"."can_block_users") FILTER (WHERE ("tp"."is_active" AND ("tp"."expires_at" > "now"()))), false)) AS "effective_can_block_users",
    (COALESCE("r"."can_unblock_users", false) OR COALESCE("bool_or"("tr"."can_unblock_users") FILTER (WHERE ("tp"."is_active" AND ("tp"."expires_at" > "now"()))), false)) AS "effective_can_unblock_users",
    (COALESCE("r"."can_ban_users", false) OR COALESCE("bool_or"("tr"."can_ban_users") FILTER (WHERE ("tp"."is_active" AND ("tp"."expires_at" > "now"()))), false)) AS "effective_can_ban_users",
    (COALESCE("r"."can_reset_passwords", false) OR COALESCE("bool_or"("tr"."can_reset_passwords") FILTER (WHERE ("tp"."is_active" AND ("tp"."expires_at" > "now"()))), false)) AS "effective_can_reset_passwords",
    (COALESCE("r"."can_delete_profiles", false) OR COALESCE("bool_or"("tr"."can_delete_profiles") FILTER (WHERE ("tp"."is_active" AND ("tp"."expires_at" > "now"()))), false)) AS "effective_can_delete_profiles",
    (COALESCE("r"."can_manage_roles", false) OR COALESCE("bool_or"("tr"."can_manage_roles") FILTER (WHERE ("tp"."is_active" AND ("tp"."expires_at" > "now"()))), false)) AS "effective_can_manage_roles",
    "array_agg"(
        CASE
            WHEN ("tp"."is_active" AND ("tp"."expires_at" > "now"())) THEN "json_build_object"('role_name', "tr"."name", 'expires_at', "tp"."expires_at", 'reason', "tp"."reason", 'granted_by', "gp"."full_name")
            ELSE NULL::json
        END) FILTER (WHERE ("tp"."is_active" AND ("tp"."expires_at" > "now"()))) AS "active_temp_privileges"
   FROM (((("public"."profiles" "p"
     LEFT JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
     LEFT JOIN "public"."temporary_privileges" "tp" ON (("p"."id" = "tp"."user_id")))
     LEFT JOIN "public"."roles" "tr" ON (("tp"."granted_role_id" = "tr"."id")))
     LEFT JOIN "public"."profiles" "gp" ON (("tp"."granted_by" = "gp"."id")))
  WHERE (("r"."name" <> 'customer'::"text") OR ("r"."name" IS NULL))
  GROUP BY "p"."id", "p"."full_name", "p"."username", "p"."status", "p"."packer_status", "r"."name", "r"."can_block_users", "r"."can_unblock_users", "r"."can_ban_users", "r"."can_reset_passwords", "r"."can_delete_profiles", "r"."can_manage_roles";


ALTER VIEW "public"."user_effective_permissions" OWNER TO "postgres";


ALTER TABLE ONLY "public"."allocation_increase_requests"
    ADD CONSTRAINT "allocation_increase_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_settings"
    ADD CONSTRAINT "app_settings_key_key" UNIQUE ("key");



ALTER TABLE ONLY "public"."app_settings"
    ADD CONSTRAINT "app_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."attendance_logs"
    ADD CONSTRAINT "attendance_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."beam"
    ADD CONSTRAINT "beam_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."box_type"
    ADD CONSTRAINT "box_type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."category_tag_map"
    ADD CONSTRAINT "category_tag_map_pkey" PRIMARY KEY ("category_id", "tag_id");



ALTER TABLE ONLY "public"."client_order"
    ADD CONSTRAINT "client_order_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_portal_settings"
    ADD CONSTRAINT "client_portal_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_portal_settings"
    ADD CONSTRAINT "client_portal_settings_portal_slug_key" UNIQUE ("portal_slug");



ALTER TABLE ONLY "public"."client_quality_control"
    ADD CONSTRAINT "client_quality_control_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_report_collaborators"
    ADD CONSTRAINT "client_report_collaborators_client_report_id_profile_id_key" UNIQUE ("client_report_id", "profile_id");



ALTER TABLE ONLY "public"."client_report_collaborators"
    ADD CONSTRAINT "client_report_collaborators_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_report_orders"
    ADD CONSTRAINT "client_report_orders_client_report_id_order_id_key" UNIQUE ("client_report_id", "order_id");



ALTER TABLE ONLY "public"."client_report_orders"
    ADD CONSTRAINT "client_report_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_report"
    ADD CONSTRAINT "client_report_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_report"
    ADD CONSTRAINT "client_report_report_number_key" UNIQUE ("report_number");



ALTER TABLE ONLY "public"."client_shipment"
    ADD CONSTRAINT "client_shipment_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clients"
    ADD CONSTRAINT "clients_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."clients"
    ADD CONSTRAINT "clients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."destinations"
    ADD CONSTRAINT "destinations_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."destinations"
    ADD CONSTRAINT "destinations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."import_taqa3_catalog"
    ADD CONSTRAINT "import_taqa3_catalog_pkey" PRIMARY KEY ("item_num");



ALTER TABLE ONLY "public"."instance_c_report_map"
    ADD CONSTRAINT "instance_c_report_map_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."items_db"
    ADD CONSTRAINT "maintenance_db_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pkd_item"
    ADD CONSTRAINT "maintenance_package_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."maintenance_task_assignments"
    ADD CONSTRAINT "maintenance_task_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."maintenance_task_assignments"
    ADD CONSTRAINT "maintenance_task_assignments_unique" UNIQUE ("maintenance_task_log_id", "packer_id");



ALTER TABLE ONLY "public"."maintenance_task_log"
    ADD CONSTRAINT "maintenance_task_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."maintenance_task_log"
    ADD CONSTRAINT "maintenance_task_log_sequence_unique" UNIQUE ("order_package_id", "sequence_order");



ALTER TABLE ONLY "public"."material_requests"
    ADD CONSTRAINT "material_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."material_tags"
    ADD CONSTRAINT "material_tags_pkey" PRIMARY KEY ("material_id", "tag_id");



ALTER TABLE ONLY "public"."material_variant_requests"
    ADD CONSTRAINT "material_variant_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."material_variant_tags"
    ADD CONSTRAINT "material_variant_tags_pkey" PRIMARY KEY ("material_variant_id", "tag_id");



ALTER TABLE ONLY "public"."material_variants"
    ADD CONSTRAINT "material_variants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."materials"
    ADD CONSTRAINT "materials_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."materials"
    ADD CONSTRAINT "materials_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_item_allocation"
    ADD CONSTRAINT "order_item_allocation_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_item_allocation"
    ADD CONSTRAINT "order_item_allocation_uniq" UNIQUE ("order_id", "items_db_id", "destination_id");



ALTER TABLE ONLY "public"."order_package_materials"
    ADD CONSTRAINT "order_package_materials_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_package_securing"
    ADD CONSTRAINT "order_package_securing_order_package_id_securing_side_is_fi_key" UNIQUE ("order_package_id", "securing_side", "is_final");



ALTER TABLE ONLY "public"."order_package_securing"
    ADD CONSTRAINT "order_package_securing_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_package_services"
    ADD CONSTRAINT "order_package_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_packages"
    ADD CONSTRAINT "order_packages_order_id_package_number_key" UNIQUE ("order_id", "package_number");



ALTER TABLE ONLY "public"."order_packages"
    ADD CONSTRAINT "order_packages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_pkg_instance"
    ADD CONSTRAINT "order_pkg_instance_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_pkg_instance"
    ADD CONSTRAINT "order_pkg_instance_unique_per_overview" UNIQUE ("order_pkg_overview_id", "instance_number");



ALTER TABLE ONLY "public"."order_pkg_overview"
    ADD CONSTRAINT "order_pkg_overview_order_pkg_number_unique" UNIQUE ("order_id", "pkg_number");



ALTER TABLE ONLY "public"."order_pkg_overview"
    ADD CONSTRAINT "order_pkg_overview_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_team_members"
    ADD CONSTRAINT "order_team_members_order_team_id_packer_id_key" UNIQUE ("order_id", "packer_id");



ALTER TABLE ONLY "public"."order_team_members"
    ADD CONSTRAINT "order_team_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."package_info"
    ADD CONSTRAINT "package_info_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."package_items"
    ADD CONSTRAINT "package_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."packer_sessions"
    ADD CONSTRAINT "packer_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."packing_types"
    ADD CONSTRAINT "packing_types_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."packing_types"
    ADD CONSTRAINT "packing_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pkg_category"
    ADD CONSTRAINT "pkg_category_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."project_tags"
    ADD CONSTRAINT "project_tags_name_client_id_key" UNIQUE ("name", "client_id");



ALTER TABLE ONLY "public"."project_tags"
    ADD CONSTRAINT "project_tags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."qr_codes"
    ADD CONSTRAINT "qr_codes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."qr_codes"
    ADD CONSTRAINT "qr_codes_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."report_batch"
    ADD CONSTRAINT "report_batch_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."report_template_settings"
    ADD CONSTRAINT "report_template_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."request_audit_log"
    ADD CONSTRAINT "request_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."securing_template"
    ADD CONSTRAINT "securing_template_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sei_categories"
    ADD CONSTRAINT "sei_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sei_protection"
    ADD CONSTRAINT "sei_protection_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."services"
    ADD CONSTRAINT "services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."signatures"
    ADD CONSTRAINT "signatures_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."supplier_email_messages"
    ADD CONSTRAINT "supplier_email_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."supplier_pricing"
    ADD CONSTRAINT "supplier_pricing_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."supplier_pricing_requests"
    ADD CONSTRAINT "supplier_pricing_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."suppliers"
    ADD CONSTRAINT "suppliers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tags"
    ADD CONSTRAINT "tags_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."tags"
    ADD CONSTRAINT "tags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_assignments"
    ADD CONSTRAINT "task_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_assignments"
    ADD CONSTRAINT "task_assignments_task_id_packer_id_key" UNIQUE ("task_id", "packer_id");



ALTER TABLE ONLY "public"."task_logs"
    ADD CONSTRAINT "task_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_packages"
    ADD CONSTRAINT "task_packages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_packages"
    ADD CONSTRAINT "task_packages_task_id_order_package_id_key" UNIQUE ("task_log_id", "order_package_id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."temporary_privileges"
    ADD CONSTRAINT "temporary_privileges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transportation"
    ADD CONSTRAINT "transportation_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."units_of_measure"
    ADD CONSTRAINT "units_of_measure_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."units_of_measure"
    ADD CONSTRAINT "units_of_measure_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_alloc_increase_req_order" ON "public"."allocation_increase_requests" USING "btree" ("order_id");



CREATE INDEX "idx_alloc_increase_req_requested_at" ON "public"."allocation_increase_requests" USING "btree" ("requested_at");



CREATE INDEX "idx_app_settings_category" ON "public"."app_settings" USING "btree" ("category");



CREATE INDEX "idx_app_settings_key" ON "public"."app_settings" USING "btree" ("key");



CREATE INDEX "idx_attendance_logs_date_packer" ON "public"."attendance_logs" USING "btree" ("log_date", "packer_id", "order_id");



CREATE INDEX "idx_attendance_logs_order_id" ON "public"."attendance_logs" USING "btree" ("order_id");



CREATE INDEX "idx_attendance_logs_packer_id" ON "public"."attendance_logs" USING "btree" ("packer_id");



CREATE INDEX "idx_audit_log_changed_by" ON "public"."audit_log" USING "btree" ("changed_by");



CREATE INDEX "idx_audit_log_order_id" ON "public"."audit_log" USING "btree" ("order_id");



CREATE INDEX "idx_audit_log_order_package" ON "public"."audit_log" USING "btree" ("order_package_id");



CREATE INDEX "idx_beam_type" ON "public"."beam" USING "btree" ("type");



CREATE INDEX "idx_maintenance_db_client" ON "public"."items_db" USING "btree" ("client_id");



CREATE INDEX "idx_maintenance_task_assignments_packer" ON "public"."maintenance_task_assignments" USING "btree" ("packer_id");



CREATE INDEX "idx_maintenance_task_assignments_task_log" ON "public"."maintenance_task_assignments" USING "btree" ("maintenance_task_log_id");



CREATE INDEX "idx_maintenance_task_log_order_package_id" ON "public"."maintenance_task_log" USING "btree" ("order_package_id");



CREATE INDEX "idx_maintenance_task_log_task_status" ON "public"."maintenance_task_log" USING "btree" ("task_status");



CREATE INDEX "idx_material_tags_tag_id" ON "public"."material_tags" USING "btree" ("tag_id");



CREATE INDEX "idx_material_variants_material_id" ON "public"."material_variants" USING "btree" ("material_id");



CREATE INDEX "idx_material_variants_pending_approval" ON "public"."material_variants" USING "btree" ("pending_approval", "approval_status") WHERE ("pending_approval" = true);



CREATE INDEX "idx_materials_pending_approval" ON "public"."materials" USING "btree" ("pending_approval", "approval_status") WHERE ("pending_approval" = true);



CREATE INDEX "idx_materials_unit_id" ON "public"."materials" USING "btree" ("unit_id");



CREATE INDEX "idx_media_maintenance_task_log_id" ON "public"."media" USING "btree" ("maintenance_task_log_id");



CREATE INDEX "idx_mvr_material_request_id" ON "public"."material_variant_requests" USING "btree" ("material_request_id");



CREATE INDEX "idx_oia_dest" ON "public"."order_item_allocation" USING "btree" ("destination_id");



CREATE INDEX "idx_oia_item" ON "public"."order_item_allocation" USING "btree" ("items_db_id");



CREATE INDEX "idx_oia_order" ON "public"."order_item_allocation" USING "btree" ("order_id");



CREATE INDEX "idx_order_package_materials_material_variant_id" ON "public"."order_package_materials" USING "btree" ("material_variant_id");



CREATE INDEX "idx_order_package_materials_order_package_id" ON "public"."order_package_materials" USING "btree" ("order_package_id");



CREATE INDEX "idx_order_package_materials_original" ON "public"."order_package_materials" USING "btree" ("original");



CREATE INDEX "idx_order_package_materials_unit_id" ON "public"."order_package_materials" USING "btree" ("unit_id");



CREATE INDEX "idx_order_package_securing_securing_template_id" ON "public"."order_package_securing" USING "btree" ("securing_template_id");



CREATE INDEX "idx_order_package_services_order_package_id" ON "public"."order_package_services" USING "btree" ("order_package_id");



CREATE INDEX "idx_order_package_services_service_id" ON "public"."order_package_services" USING "btree" ("service_id");



CREATE INDEX "idx_order_packages_final_pkg_info" ON "public"."order_packages" USING "btree" ("final_pkg_info");



CREATE INDEX "idx_order_packages_original_pkg_info" ON "public"."order_packages" USING "btree" ("original_pkg_info");



CREATE INDEX "idx_order_pkg_instance_order_package_id" ON "public"."order_pkg_instance" USING "btree" ("order_package_id");



CREATE INDEX "idx_order_pkg_instance_overview_id" ON "public"."order_pkg_instance" USING "btree" ("order_pkg_overview_id");



CREATE INDEX "idx_order_pkg_instance_status" ON "public"."order_pkg_instance" USING "btree" ("status");



CREATE INDEX "idx_order_pkg_overview_order_id" ON "public"."order_pkg_overview" USING "btree" ("order_id");



CREATE INDEX "idx_order_pkg_overview_status" ON "public"."order_pkg_overview" USING "btree" ("status");



CREATE INDEX "idx_order_team_members_packer_id" ON "public"."order_team_members" USING "btree" ("packer_id");



CREATE INDEX "idx_orders_client_id" ON "public"."orders" USING "btree" ("client_id");



CREATE INDEX "idx_orders_created_by" ON "public"."orders" USING "btree" ("created_by");



CREATE INDEX "idx_package_info_packing_type_id" ON "public"."package_info" USING "btree" ("packing_type_id");



CREATE INDEX "idx_package_items_order_package_id" ON "public"."package_items" USING "btree" ("order_package_id");



CREATE INDEX "idx_packer_sessions_order_id" ON "public"."packer_sessions" USING "btree" ("order_id");



CREATE INDEX "idx_packer_sessions_packer_active" ON "public"."packer_sessions" USING "btree" ("packer_id", "session_active");



CREATE UNIQUE INDEX "idx_packer_sessions_single_active_per_packer" ON "public"."packer_sessions" USING "btree" ("packer_id") WHERE ("session_active" = true);



CREATE INDEX "idx_pkd_item_pkg_instance_id" ON "public"."pkd_item" USING "btree" ("pkg_instance_id");



CREATE INDEX "idx_profiles_current_order" ON "public"."profiles" USING "btree" ("current_order_id");



CREATE INDEX "idx_profiles_packer_status" ON "public"."profiles" USING "btree" ("packer_status");



CREATE INDEX "idx_profiles_role_id" ON "public"."profiles" USING "btree" ("role_id");



CREATE INDEX "idx_qr_codes_entity" ON "public"."qr_codes" USING "btree" ("entity_id");



CREATE INDEX "idx_qr_codes_token" ON "public"."qr_codes" USING "btree" ("token");



CREATE INDEX "idx_request_audit_log_requested_by" ON "public"."request_audit_log" USING "btree" ("requested_by");



CREATE INDEX "idx_request_audit_log_resulting_id" ON "public"."request_audit_log" USING "btree" ("resulting_id");



CREATE INDEX "idx_request_audit_log_reviewed_by" ON "public"."request_audit_log" USING "btree" ("reviewed_by");



CREATE INDEX "idx_request_audit_log_type" ON "public"."request_audit_log" USING "btree" ("request_type");



CREATE INDEX "idx_securing_template_horizontal_bar" ON "public"."securing_template" USING "btree" ("horizontal_bar");



CREATE INDEX "idx_securing_template_skids" ON "public"."securing_template" USING "btree" ("skids");



CREATE INDEX "idx_securing_template_type_id" ON "public"."securing_template" USING "btree" ("type_id");



CREATE INDEX "idx_securing_template_vertical_bar" ON "public"."securing_template" USING "btree" ("vertical_bar");



CREATE INDEX "idx_services_tag_id" ON "public"."services" USING "btree" ("tag_id");



CREATE INDEX "idx_spr_variant_request_id" ON "public"."supplier_pricing_requests" USING "btree" ("variant_request_id");



CREATE INDEX "idx_supplier_email_messages_created_at" ON "public"."supplier_email_messages" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_supplier_email_messages_supplier_id" ON "public"."supplier_email_messages" USING "btree" ("supplier_id");



CREATE INDEX "idx_supplier_pricing_material_variant_id" ON "public"."supplier_pricing" USING "btree" ("material_variant_id");



CREATE INDEX "idx_supplier_pricing_pending_approval" ON "public"."supplier_pricing" USING "btree" ("pending_approval", "approval_status") WHERE ("pending_approval" = true);



CREATE INDEX "idx_task_assignments_packer_id" ON "public"."task_assignments" USING "btree" ("packer_id");



CREATE INDEX "idx_task_assignments_task_id" ON "public"."task_assignments" USING "btree" ("task_id");



CREATE INDEX "idx_task_logs_task_id" ON "public"."task_logs" USING "btree" ("task_id");



CREATE INDEX "idx_task_packages_order_package_id" ON "public"."task_packages" USING "btree" ("order_package_id");



CREATE INDEX "idx_task_packages_task_id" ON "public"."task_packages" USING "btree" ("task_log_id");



CREATE INDEX "idx_temporary_privileges_granted_by" ON "public"."temporary_privileges" USING "btree" ("granted_by");



CREATE INDEX "idx_temporary_privileges_granted_role_id" ON "public"."temporary_privileges" USING "btree" ("granted_role_id");



CREATE INDEX "idx_transportation_order_id" ON "public"."transportation" USING "btree" ("order_id");



CREATE INDEX "idx_transportation_recorded_by" ON "public"."transportation" USING "btree" ("recorded_by");



CREATE INDEX "idx_transportation_unit_id" ON "public"."transportation" USING "btree" ("unit_id");



CREATE UNIQUE INDEX "items_db_client_id_item_num_key" ON "public"."items_db" USING "btree" ("client_id", "item_num");



CREATE UNIQUE INDEX "uq_supplier_email_messages_resend_email_id" ON "public"."supplier_email_messages" USING "btree" ("resend_email_id") WHERE ("resend_email_id" IS NOT NULL);



CREATE OR REPLACE TRIGGER "guard_profile_security_fields" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."guard_profile_security_fields"();



CREATE OR REPLACE TRIGGER "trg_assign_report_number" BEFORE INSERT ON "public"."client_report" FOR EACH ROW EXECUTE FUNCTION "public"."assign_report_number"();



CREATE OR REPLACE TRIGGER "trg_cleanup_order_pkg_instance_qr" AFTER DELETE ON "public"."order_pkg_instance" FOR EACH ROW EXECUTE FUNCTION "public"."cleanup_order_pkg_instance_qr"();



CREATE OR REPLACE TRIGGER "trg_client_report_updated_at" BEFORE UPDATE ON "public"."client_report" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "trg_ensure_order_pkg_instance_qr" AFTER INSERT ON "public"."order_pkg_instance" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_order_pkg_instance_qr"();



CREATE OR REPLACE TRIGGER "trg_instance_destination_packed_sync" AFTER UPDATE OF "destination" ON "public"."order_pkg_instance" FOR EACH ROW WHEN (("old"."destination" IS DISTINCT FROM "new"."destination")) EXECUTE FUNCTION "public"."trg_instance_destination_packed_sync"();



CREATE OR REPLACE TRIGGER "trg_order_pkg_instance_rollup" AFTER INSERT OR DELETE OR UPDATE OF "status", "order_pkg_overview_id" ON "public"."order_pkg_instance" FOR EACH ROW EXECUTE FUNCTION "public"."trg_order_pkg_instance_rollup"();



CREATE OR REPLACE TRIGGER "trg_pkd_item_packed_sync" AFTER INSERT OR DELETE OR UPDATE ON "public"."pkd_item" FOR EACH ROW EXECUTE FUNCTION "public"."trg_pkd_item_packed_sync"();



CREATE OR REPLACE TRIGGER "trg_set_order_pkg_instance_updated_at" BEFORE UPDATE ON "public"."order_pkg_instance" FOR EACH ROW EXECUTE FUNCTION "public"."set_order_pkg_instance_updated_at"();



CREATE OR REPLACE TRIGGER "trg_set_order_pkg_overview_updated_at" BEFORE UPDATE ON "public"."order_pkg_overview" FOR EACH ROW EXECUTE FUNCTION "public"."set_order_pkg_overview_updated_at"();



CREATE OR REPLACE TRIGGER "trg_stamp_instance_packed_at_on_package_packed" AFTER UPDATE OF "status" ON "public"."order_packages" FOR EACH ROW EXECUTE FUNCTION "public"."stamp_instance_packed_at_on_package_packed"();



CREATE OR REPLACE TRIGGER "trg_sync_profile_on_order_team_delete" AFTER DELETE ON "public"."order_team_members" FOR EACH ROW EXECUTE FUNCTION "public"."sync_profile_on_order_team_change"();



CREATE OR REPLACE TRIGGER "trg_sync_profile_on_order_team_insert" AFTER INSERT ON "public"."order_team_members" FOR EACH ROW EXECUTE FUNCTION "public"."sync_profile_on_order_team_change"();



CREATE OR REPLACE TRIGGER "trigger_enforce_single_active_order_for_packer" BEFORE INSERT OR UPDATE OF "order_id", "packer_id" ON "public"."order_team_members" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_single_active_order_for_packer"();



CREATE OR REPLACE TRIGGER "trigger_handle_empty_order" AFTER DELETE ON "public"."order_team_members" FOR EACH ROW EXECUTE FUNCTION "public"."handle_empty_order"();



CREATE OR REPLACE TRIGGER "trigger_log_packer_status_change" AFTER UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."log_packer_status_change"();



CREATE OR REPLACE TRIGGER "trigger_update_packer_status_on_completion" AFTER UPDATE ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."update_packer_status_on_order_completion"();



CREATE OR REPLACE TRIGGER "trigger_update_packer_status_on_team_change" AFTER INSERT OR DELETE ON "public"."order_team_members" FOR EACH ROW EXECUTE FUNCTION "public"."update_packer_status_on_assignment"();



CREATE OR REPLACE TRIGGER "update_app_settings_updated_at" BEFORE UPDATE ON "public"."app_settings" FOR EACH ROW EXECUTE FUNCTION "public"."update_app_settings_updated_at"();



CREATE OR REPLACE TRIGGER "update_maintenance_task_assignments_modtime" BEFORE UPDATE ON "public"."maintenance_task_assignments" FOR EACH ROW EXECUTE FUNCTION "public"."set_maintenance_task_assignments_updated_at"();



CREATE OR REPLACE TRIGGER "update_maintenance_task_log_modtime" BEFORE UPDATE ON "public"."maintenance_task_log" FOR EACH ROW EXECUTE FUNCTION "public"."set_maintenance_task_log_updated_at"();



ALTER TABLE ONLY "public"."allocation_increase_requests"
    ADD CONSTRAINT "allocation_increase_requests_destination_id_fkey" FOREIGN KEY ("destination_id") REFERENCES "public"."destinations"("id");



ALTER TABLE ONLY "public"."allocation_increase_requests"
    ADD CONSTRAINT "allocation_increase_requests_items_db_id_fkey" FOREIGN KEY ("items_db_id") REFERENCES "public"."items_db"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."allocation_increase_requests"
    ADD CONSTRAINT "allocation_increase_requests_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."allocation_increase_requests"
    ADD CONSTRAINT "allocation_increase_requests_order_package_context_fkey" FOREIGN KEY ("order_package_context") REFERENCES "public"."order_packages"("id");



ALTER TABLE ONLY "public"."allocation_increase_requests"
    ADD CONSTRAINT "allocation_increase_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."attendance_logs"
    ADD CONSTRAINT "attendance_logs_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."attendance_logs"
    ADD CONSTRAINT "attendance_logs_packer_id_fkey" FOREIGN KEY ("packer_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_changed_by_fkey" FOREIGN KEY ("changed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_order_package_id_fkey" FOREIGN KEY ("order_package_id") REFERENCES "public"."order_packages"("id");



ALTER TABLE ONLY "public"."beam"
    ADD CONSTRAINT "beam_type_fkey" FOREIGN KEY ("type") REFERENCES "public"."material_variants"("id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."category_order_map"
    ADD CONSTRAINT "category_order_map_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."pkg_category"("id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."category_order_map"
    ADD CONSTRAINT "category_order_map_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."category_tag_map"
    ADD CONSTRAINT "category_tag_map_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."pkg_category"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."category_tag_map"
    ADD CONSTRAINT "category_tag_map_tag_id_fkey" FOREIGN KEY ("tag_id") REFERENCES "public"."project_tags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_order"
    ADD CONSTRAINT "client_order_client_report_id_fkey" FOREIGN KEY ("client_report_id") REFERENCES "public"."client_report"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_order"
    ADD CONSTRAINT "client_order_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."client_quality_control"
    ADD CONSTRAINT "client_quality_control_client_report_id_fkey" FOREIGN KEY ("client_report_id") REFERENCES "public"."client_report"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_report"
    ADD CONSTRAINT "client_report_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."report_batch"("id");



ALTER TABLE ONLY "public"."client_report"
    ADD CONSTRAINT "client_report_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."client_report_collaborators"
    ADD CONSTRAINT "client_report_collaborators_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."client_report_collaborators"
    ADD CONSTRAINT "client_report_collaborators_client_report_id_fkey" FOREIGN KEY ("client_report_id") REFERENCES "public"."client_report"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_report_collaborators"
    ADD CONSTRAINT "client_report_collaborators_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."client_report"
    ADD CONSTRAINT "client_report_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."client_report_orders"
    ADD CONSTRAINT "client_report_orders_client_report_id_fkey" FOREIGN KEY ("client_report_id") REFERENCES "public"."client_report"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_report_orders"
    ADD CONSTRAINT "client_report_orders_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."client_report"
    ADD CONSTRAINT "client_report_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."report_template_settings"("id");



ALTER TABLE ONLY "public"."client_shipment"
    ADD CONSTRAINT "client_shipment_client_report_id_fkey" FOREIGN KEY ("client_report_id") REFERENCES "public"."client_report"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."clients"
    ADD CONSTRAINT "clients_portal_settings_id_fkey" FOREIGN KEY ("portal_settings_id") REFERENCES "public"."client_portal_settings"("id");



ALTER TABLE ONLY "public"."instance_c_report_map"
    ADD CONSTRAINT "instance_c_report_map_client_report_id_fkey" FOREIGN KEY ("client_report_id") REFERENCES "public"."client_report"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."instance_c_report_map"
    ADD CONSTRAINT "instance_c_report_map_package_instance_id_fkey" FOREIGN KEY ("package_instance_id") REFERENCES "public"."order_pkg_instance"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."items_db"
    ADD CONSTRAINT "items_db_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."pkg_category"("id");



ALTER TABLE ONLY "public"."items_db"
    ADD CONSTRAINT "maintenance_db_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pkd_item"
    ADD CONSTRAINT "maintenance_package_items_maintenance_db_id_fkey" FOREIGN KEY ("maintenance_db_id") REFERENCES "public"."items_db"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."maintenance_task_assignments"
    ADD CONSTRAINT "maintenance_task_assignments_maintenance_task_log_id_fkey" FOREIGN KEY ("maintenance_task_log_id") REFERENCES "public"."maintenance_task_log"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."maintenance_task_assignments"
    ADD CONSTRAINT "maintenance_task_assignments_packer_id_fkey" FOREIGN KEY ("packer_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."maintenance_task_log"
    ADD CONSTRAINT "maintenance_task_log_order_package_id_fkey" FOREIGN KEY ("order_package_id") REFERENCES "public"."order_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."maintenance_task_log"
    ADD CONSTRAINT "maintenance_task_log_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id");



ALTER TABLE ONLY "public"."material_requests"
    ADD CONSTRAINT "material_requests_order_package_context_fkey" FOREIGN KEY ("order_package_context") REFERENCES "public"."order_packages"("id");



ALTER TABLE ONLY "public"."material_requests"
    ADD CONSTRAINT "material_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."material_requests"
    ADD CONSTRAINT "material_requests_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units_of_measure"("id");



ALTER TABLE ONLY "public"."material_tags"
    ADD CONSTRAINT "material_tags_material_id_fkey" FOREIGN KEY ("material_id") REFERENCES "public"."materials"("id");



ALTER TABLE ONLY "public"."material_tags"
    ADD CONSTRAINT "material_tags_tag_id_fkey" FOREIGN KEY ("tag_id") REFERENCES "public"."tags"("id");



ALTER TABLE ONLY "public"."material_variant_requests"
    ADD CONSTRAINT "material_variant_requests_material_id_fkey" FOREIGN KEY ("material_id") REFERENCES "public"."materials"("id");



ALTER TABLE ONLY "public"."material_variant_requests"
    ADD CONSTRAINT "material_variant_requests_material_request_id_fkey" FOREIGN KEY ("material_request_id") REFERENCES "public"."material_requests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."material_variant_requests"
    ADD CONSTRAINT "material_variant_requests_order_package_context_fkey" FOREIGN KEY ("order_package_context") REFERENCES "public"."order_packages"("id");



ALTER TABLE ONLY "public"."material_variant_requests"
    ADD CONSTRAINT "material_variant_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."material_variant_requests"
    ADD CONSTRAINT "material_variant_requests_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units_of_measure"("id");



ALTER TABLE ONLY "public"."material_variant_tags"
    ADD CONSTRAINT "material_variant_tags_material_variant_id_fkey" FOREIGN KEY ("material_variant_id") REFERENCES "public"."material_variants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."material_variant_tags"
    ADD CONSTRAINT "material_variant_tags_tag_id_fkey" FOREIGN KEY ("tag_id") REFERENCES "public"."tags"("id") ON UPDATE RESTRICT ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."material_variants"
    ADD CONSTRAINT "material_variants_material_id_fkey" FOREIGN KEY ("material_id") REFERENCES "public"."materials"("id");



ALTER TABLE ONLY "public"."material_variants"
    ADD CONSTRAINT "material_variants_order_package_context_fkey" FOREIGN KEY ("order_package_context") REFERENCES "public"."order_packages"("id");



ALTER TABLE ONLY "public"."material_variants"
    ADD CONSTRAINT "material_variants_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."material_variants"
    ADD CONSTRAINT "material_variants_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."material_variants"
    ADD CONSTRAINT "material_variants_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units_of_measure"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."materials"
    ADD CONSTRAINT "materials_order_package_context_fkey" FOREIGN KEY ("order_package_context") REFERENCES "public"."order_packages"("id");



ALTER TABLE ONLY "public"."materials"
    ADD CONSTRAINT "materials_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."materials"
    ADD CONSTRAINT "materials_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."materials"
    ADD CONSTRAINT "materials_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units_of_measure"("id");



ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_maintenance_task_log_id_fkey" FOREIGN KEY ("maintenance_task_log_id") REFERENCES "public"."maintenance_task_log"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_order_package_id_fkey" FOREIGN KEY ("order_package_id") REFERENCES "public"."order_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_order_pkg_instance_id_fkey" FOREIGN KEY ("order_pkg_instance_id") REFERENCES "public"."order_pkg_instance"("id");



ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_package_item_id_fkey" FOREIGN KEY ("package_item_id") REFERENCES "public"."package_items"("id");



ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_pkd_item_id_fkey" FOREIGN KEY ("pkd_item_id") REFERENCES "public"."pkd_item"("id");



ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_task_log_id_fkey" FOREIGN KEY ("task_log_id") REFERENCES "public"."task_logs"("id");



ALTER TABLE ONLY "public"."order_item_allocation"
    ADD CONSTRAINT "order_item_allocation_destination_id_fkey" FOREIGN KEY ("destination_id") REFERENCES "public"."destinations"("id");



ALTER TABLE ONLY "public"."order_item_allocation"
    ADD CONSTRAINT "order_item_allocation_items_db_id_fkey" FOREIGN KEY ("items_db_id") REFERENCES "public"."items_db"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."order_item_allocation"
    ADD CONSTRAINT "order_item_allocation_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_package_materials"
    ADD CONSTRAINT "order_package_materials_material_variant_id_fkey" FOREIGN KEY ("material_variant_id") REFERENCES "public"."material_variants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_package_materials"
    ADD CONSTRAINT "order_package_materials_order_package_id_fkey" FOREIGN KEY ("order_package_id") REFERENCES "public"."order_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_package_materials"
    ADD CONSTRAINT "order_package_materials_original_fkey" FOREIGN KEY ("original") REFERENCES "public"."order_package_materials"("id");



ALTER TABLE ONLY "public"."order_package_materials"
    ADD CONSTRAINT "order_package_materials_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units_of_measure"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."order_package_materials"
    ADD CONSTRAINT "order_package_materials_variant_request_id_fkey" FOREIGN KEY ("variant_request_id") REFERENCES "public"."material_variant_requests"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order_package_securing"
    ADD CONSTRAINT "order_package_securing_order_package_id_fkey" FOREIGN KEY ("order_package_id") REFERENCES "public"."order_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_package_securing"
    ADD CONSTRAINT "order_package_securing_securing_template_id_fkey" FOREIGN KEY ("securing_template_id") REFERENCES "public"."securing_template"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."order_package_services"
    ADD CONSTRAINT "order_package_services_order_package_id_fkey" FOREIGN KEY ("order_package_id") REFERENCES "public"."order_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_package_services"
    ADD CONSTRAINT "order_package_services_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "public"."services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_packages"
    ADD CONSTRAINT "order_packages_final_pkg_info_fkey" FOREIGN KEY ("final_pkg_info") REFERENCES "public"."package_info"("id");



ALTER TABLE ONLY "public"."order_packages"
    ADD CONSTRAINT "order_packages_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."order_packages"
    ADD CONSTRAINT "order_packages_original_pkg_info_fkey" FOREIGN KEY ("original_pkg_info") REFERENCES "public"."package_info"("id");



ALTER TABLE ONLY "public"."order_pkg_instance"
    ADD CONSTRAINT "order_pkg_instance_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."pkg_category"("id");



ALTER TABLE ONLY "public"."order_pkg_instance"
    ADD CONSTRAINT "order_pkg_instance_order_package_id_fkey" FOREIGN KEY ("order_package_id") REFERENCES "public"."order_packages"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."order_pkg_instance"
    ADD CONSTRAINT "order_pkg_instance_order_pkg_overview_id_fkey" FOREIGN KEY ("order_pkg_overview_id") REFERENCES "public"."order_pkg_overview"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_pkg_overview"
    ADD CONSTRAINT "order_pkg_overview_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_team_members"
    ADD CONSTRAINT "order_team_members_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."order_team_members"
    ADD CONSTRAINT "order_team_members_packer_id_fkey" FOREIGN KEY ("packer_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_project_lead_id_fkey" FOREIGN KEY ("project_lead_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."package_info"
    ADD CONSTRAINT "package_info_box_type_id_fkey" FOREIGN KEY ("box_type_id") REFERENCES "public"."box_type"("id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."package_info"
    ADD CONSTRAINT "package_info_packing_type_id_fkey" FOREIGN KEY ("packing_type_id") REFERENCES "public"."packing_types"("id");



ALTER TABLE ONLY "public"."package_info"
    ADD CONSTRAINT "package_info_sei_category_fkey" FOREIGN KEY ("sei_category") REFERENCES "public"."sei_categories"("id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."package_info"
    ADD CONSTRAINT "package_info_sei_protection_fkey" FOREIGN KEY ("sei_protection") REFERENCES "public"."sei_protection"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."package_items"
    ADD CONSTRAINT "package_items_items_db_id_fkey" FOREIGN KEY ("items_db_id") REFERENCES "public"."items_db"("id");



ALTER TABLE ONLY "public"."package_items"
    ADD CONSTRAINT "package_items_order_package_id_fkey" FOREIGN KEY ("order_package_id") REFERENCES "public"."order_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."packer_sessions"
    ADD CONSTRAINT "packer_sessions_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."packer_sessions"
    ADD CONSTRAINT "packer_sessions_packer_id_fkey" FOREIGN KEY ("packer_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pkd_item"
    ADD CONSTRAINT "pkd_item_pkg_instance_id_fkey" FOREIGN KEY ("pkg_instance_id") REFERENCES "public"."order_pkg_instance"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pkg_category"
    ADD CONSTRAINT "pkg_category_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_current_order_id_fkey" FOREIGN KEY ("current_order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id");



ALTER TABLE ONLY "public"."project_tags"
    ADD CONSTRAINT "project_tags_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."report_batch"
    ADD CONSTRAINT "report_batch_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."report_template_settings"
    ADD CONSTRAINT "report_template_settings_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."report_template_settings"
    ADD CONSTRAINT "report_template_settings_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."request_audit_log"
    ADD CONSTRAINT "request_audit_log_order_package_context_fkey" FOREIGN KEY ("order_package_context") REFERENCES "public"."order_packages"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."request_audit_log"
    ADD CONSTRAINT "request_audit_log_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."request_audit_log"
    ADD CONSTRAINT "request_audit_log_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."securing_template"
    ADD CONSTRAINT "securing_template_horizontal_bar_fkey" FOREIGN KEY ("horizontal_bar") REFERENCES "public"."beam"("id");



ALTER TABLE ONLY "public"."securing_template"
    ADD CONSTRAINT "securing_template_skids_fkey" FOREIGN KEY ("skids") REFERENCES "public"."beam"("id");



ALTER TABLE ONLY "public"."securing_template"
    ADD CONSTRAINT "securing_template_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."material_variants"("id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."securing_template"
    ADD CONSTRAINT "securing_template_vertical_bar_fkey" FOREIGN KEY ("vertical_bar") REFERENCES "public"."beam"("id");



ALTER TABLE ONLY "public"."services"
    ADD CONSTRAINT "services_tag_id_fkey" FOREIGN KEY ("tag_id") REFERENCES "public"."tags"("id");



ALTER TABLE ONLY "public"."signatures"
    ADD CONSTRAINT "signatures_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."supplier_email_messages"
    ADD CONSTRAINT "supplier_email_messages_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."supplier_email_messages"
    ADD CONSTRAINT "supplier_email_messages_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."suppliers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."supplier_pricing"
    ADD CONSTRAINT "supplier_pricing_material_variant_id_fkey" FOREIGN KEY ("material_variant_id") REFERENCES "public"."material_variants"("id");



ALTER TABLE ONLY "public"."supplier_pricing"
    ADD CONSTRAINT "supplier_pricing_order_package_context_fkey" FOREIGN KEY ("order_package_context") REFERENCES "public"."order_packages"("id");



ALTER TABLE ONLY "public"."supplier_pricing"
    ADD CONSTRAINT "supplier_pricing_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."supplier_pricing_requests"
    ADD CONSTRAINT "supplier_pricing_requests_order_package_context_fkey" FOREIGN KEY ("order_package_context") REFERENCES "public"."order_packages"("id");



ALTER TABLE ONLY "public"."supplier_pricing_requests"
    ADD CONSTRAINT "supplier_pricing_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."supplier_pricing_requests"
    ADD CONSTRAINT "supplier_pricing_requests_supplier_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."suppliers"("id");



ALTER TABLE ONLY "public"."supplier_pricing_requests"
    ADD CONSTRAINT "supplier_pricing_requests_variant_fkey" FOREIGN KEY ("material_variant_id") REFERENCES "public"."material_variants"("id");



ALTER TABLE ONLY "public"."supplier_pricing_requests"
    ADD CONSTRAINT "supplier_pricing_requests_variant_request_id_fkey" FOREIGN KEY ("variant_request_id") REFERENCES "public"."material_variant_requests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."supplier_pricing"
    ADD CONSTRAINT "supplier_pricing_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."supplier_pricing"
    ADD CONSTRAINT "supplier_pricing_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."suppliers"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."task_assignments"
    ADD CONSTRAINT "task_assignments_packer_id_fkey" FOREIGN KEY ("packer_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_assignments"
    ADD CONSTRAINT "task_assignments_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."task_logs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_logs"
    ADD CONSTRAINT "task_logs_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id");



ALTER TABLE ONLY "public"."task_packages"
    ADD CONSTRAINT "task_packages_order_package_id_fkey" FOREIGN KEY ("order_package_id") REFERENCES "public"."order_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_packages"
    ADD CONSTRAINT "task_packages_task_log_id_fkey" FOREIGN KEY ("task_log_id") REFERENCES "public"."task_logs"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."temporary_privileges"
    ADD CONSTRAINT "temporary_privileges_granted_by_fkey" FOREIGN KEY ("granted_by") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."temporary_privileges"
    ADD CONSTRAINT "temporary_privileges_granted_role_id_fkey" FOREIGN KEY ("granted_role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."temporary_privileges"
    ADD CONSTRAINT "temporary_privileges_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transportation"
    ADD CONSTRAINT "transportation_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."transportation"
    ADD CONSTRAINT "transportation_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."transportation"
    ADD CONSTRAINT "transportation_unit_id_fkey" FOREIGN KEY ("unit_id") REFERENCES "public"."units_of_measure"("id");



CREATE POLICY "Admin and director can create profiles" ON "public"."profiles" FOR INSERT WITH CHECK (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin and sales can modify clients" ON "public"."clients" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text", 'sales'::"text"])));



CREATE POLICY "Admin can insert material_variants" ON "public"."material_variants" FOR INSERT TO "authenticated" WITH CHECK (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin can modify beam" ON "public"."beam" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text"]))))));



CREATE POLICY "Admin can modify material_tags" ON "public"."material_tags" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin can modify material_variants" ON "public"."material_variants" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin can modify materials" ON "public"."materials" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin can modify packing_types" ON "public"."packing_types" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin can modify securing_template" ON "public"."securing_template" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text"]))))));



CREATE POLICY "Admin can modify services" ON "public"."services" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text"]))))));



CREATE POLICY "Admin can modify supplier_pricing" ON "public"."supplier_pricing" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin can modify suppliers" ON "public"."suppliers" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text"]))))));



CREATE POLICY "Admin can modify tags" ON "public"."tags" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin can modify units_of_measure" ON "public"."units_of_measure" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin can read audit_log" ON "public"."audit_log" FOR SELECT USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin can update material_variants" ON "public"."material_variants" FOR UPDATE TO "authenticated" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"]))) WITH CHECK (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "Admin roles can modify order_packages" ON "public"."order_packages" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text", 'project_lead'::"text"])));



CREATE POLICY "Admin roles can modify transportation" ON "public"."transportation" USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text", 'project_lead'::"text"])));



CREATE POLICY "Admin roles can read all order_packages" ON "public"."order_packages" FOR SELECT USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text", 'sales'::"text", 'project_lead'::"text"])));



CREATE POLICY "Admin roles can read all orders" ON "public"."orders" FOR SELECT USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text", 'sales'::"text", 'project_lead'::"text"])));



CREATE POLICY "Admin roles can read all task_logs" ON "public"."task_logs" FOR SELECT USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text", 'project_lead'::"text"])));



CREATE POLICY "Admin roles can read clients" ON "public"."clients" FOR SELECT USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text", 'sales'::"text", 'project_lead'::"text"])));



CREATE POLICY "Admin roles can read transportation" ON "public"."transportation" FOR SELECT USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text", 'project_lead'::"text"])));



CREATE POLICY "Admin, directors and team leads can manage attendance" ON "public"."attendance_logs" TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text"])) AND ("p"."status" = 'active'::"text")))) OR "public"."is_team_lead_for_order"(( SELECT "auth"."uid"() AS "uid"), "order_id"))) WITH CHECK (((EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = "auth"."uid"()) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text"])) AND ("p"."status" = 'active'::"text")))) OR "public"."is_team_lead_for_order"("auth"."uid"(), "order_id")));



CREATE POLICY "Admin, directors and team leads can manage sessions" ON "public"."packer_sessions" TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text"])) AND ("p"."status" = 'active'::"text")))) OR (EXISTS ( SELECT 1
   FROM "public"."order_team_members" "otm"
  WHERE (("otm"."packer_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("otm"."is_team_lead" = true) AND (EXISTS ( SELECT 1
           FROM "public"."orders" "o"
          WHERE (("o"."id" = "otm"."order_id") AND ("o"."production_status" = ANY (ARRAY['pending'::"text", 'in_progress'::"text"]))))))))));



CREATE POLICY "Admins and directors can grant temporary privileges" ON "public"."temporary_privileges" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = "auth"."uid"()) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text"]))))));



CREATE POLICY "Admins and directors can revoke temporary privileges" ON "public"."temporary_privileges" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = "auth"."uid"()) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text"]))))));



CREATE POLICY "Admins can manage QR codes" ON "public"."qr_codes" USING (true);



CREATE POLICY "Admins can manage portal settings" ON "public"."client_portal_settings" USING (true);



CREATE POLICY "Admins can modify orders" ON "public"."orders" USING (("public"."get_user_role"() = 'admin'::"text")) WITH CHECK (("public"."get_user_role"() = 'admin'::"text"));



CREATE POLICY "All authenticated can read material_tags" ON "public"."material_tags" FOR SELECT USING ((( SELECT "auth"."role"() AS "role") = 'authenticated'::"text"));



CREATE POLICY "All authenticated can read packing_types" ON "public"."packing_types" FOR SELECT USING ((( SELECT "auth"."role"() AS "role") = 'authenticated'::"text"));



CREATE POLICY "All authenticated can read tags" ON "public"."tags" FOR SELECT USING ((( SELECT "auth"."role"() AS "role") = 'authenticated'::"text"));



CREATE POLICY "All authenticated can read units_of_measure" ON "public"."units_of_measure" FOR SELECT USING ((( SELECT "auth"."role"() AS "role") = 'authenticated'::"text"));



CREATE POLICY "All authenticated users can read roles" ON "public"."roles" FOR SELECT USING ((( SELECT "auth"."role"() AS "role") = 'authenticated'::"text"));



CREATE POLICY "Anyone can read destinations" ON "public"."destinations" FOR SELECT USING (true);



CREATE POLICY "Authenticated can read box_type" ON "public"."box_type" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can insert suppliers" ON "public"."suppliers" FOR INSERT WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can modify order_package_services" ON "public"."order_package_services" TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can modify order_team_members" ON "public"."order_team_members" TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can modify package_items" ON "public"."package_items" TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can modify tasks" ON "public"."tasks" TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read order_package_services" ON "public"."order_package_services" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read order_team_members" ON "public"."order_team_members" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read package_info" ON "public"."package_info" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read package_items" ON "public"."package_items" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read services" ON "public"."services" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read suppliers" ON "public"."suppliers" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read tasks" ON "public"."tasks" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Clients can read own client" ON "public"."clients" FOR SELECT USING ((("public"."get_user_role"() = 'client'::"text") AND ("id" = "public"."current_client_id"())));



CREATE POLICY "Clients can read own items_db" ON "public"."items_db" FOR SELECT USING ((("public"."get_user_role"() = 'client'::"text") AND ("client_id" = "public"."current_client_id"())));



CREATE POLICY "Clients can read own media" ON "public"."media" FOR SELECT USING ((("public"."get_user_role"() = 'client'::"text") AND ((("order_pkg_instance_id" IS NOT NULL) AND "public"."is_my_client_instance"("order_pkg_instance_id")) OR (("order_package_id" IS NOT NULL) AND "public"."is_my_client_package"("order_package_id")) OR (("pkd_item_id" IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM "public"."pkd_item" "pi"
  WHERE (("pi"."id" = "media"."pkd_item_id") AND "public"."is_my_client_instance"("pi"."pkg_instance_id"))))))));



CREATE POLICY "Clients can read own order_pkg_instance" ON "public"."order_pkg_instance" FOR SELECT USING ((("public"."get_user_role"() = 'client'::"text") AND "public"."is_my_client_instance"("id")));



CREATE POLICY "Clients can read own orders" ON "public"."orders" FOR SELECT TO "authenticated" USING (("client_id" = ( SELECT "profiles"."client_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))));



CREATE POLICY "Clients can read own overviews" ON "public"."order_pkg_overview" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_pkg_overview"."order_id") AND ("o"."client_id" = ( SELECT "profiles"."client_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"())))))));



CREATE POLICY "Clients can read own packages" ON "public"."order_packages" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_packages"."order_id") AND ("o"."client_id" = ( SELECT "profiles"."client_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"())))))));



CREATE POLICY "Clients can read own pkd_item" ON "public"."pkd_item" FOR SELECT USING ((("public"."get_user_role"() = 'client'::"text") AND "public"."is_my_client_instance"("pkg_instance_id")));



CREATE POLICY "Clients can read own pkg_category" ON "public"."pkg_category" FOR SELECT USING ((("public"."get_user_role"() = 'client'::"text") AND ("client_id" = "public"."current_client_id"())));



CREATE POLICY "Clients read own order_item_allocation" ON "public"."order_item_allocation" FOR SELECT USING ((("public"."get_user_role"() = 'client'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_item_allocation"."order_id") AND ("o"."client_id" = "public"."current_client_id"()))))));



CREATE POLICY "Delete own signature" ON "public"."signatures" FOR DELETE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Executive can read all order_packages" ON "public"."order_packages" FOR SELECT USING (("public"."get_user_role"() = 'executive'::"text"));



CREATE POLICY "Executive can read all orders" ON "public"."orders" FOR SELECT USING (("public"."get_user_role"() = 'executive'::"text"));



CREATE POLICY "Full access for authenticated users" ON "public"."category_tag_map" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Full access for authenticated users" ON "public"."project_tags" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Insert own signature" ON "public"."signatures" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Packers can add tags to pending variants" ON "public"."material_variant_tags" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."material_variants" "mv"
  WHERE (("mv"."id" = "material_variant_tags"."material_variant_id") AND ("mv"."requested_by" = "auth"."uid"()) AND ("mv"."pending_approval" = true)))));



CREATE POLICY "Packers can create own maintenance survey orders" ON "public"."orders" FOR INSERT TO "authenticated" WITH CHECK ((("public"."get_user_role"() = 'packer'::"text") AND ("created_by" = "auth"."uid"()) AND ("project_type" = ANY (ARRAY['maintenance'::"public"."project_type", 'survey'::"public"."project_type"]))));



CREATE POLICY "Packers can insert order_packages for assigned orders" ON "public"."order_packages" FOR INSERT WITH CHECK ((("public"."get_user_role"() = 'packer'::"text") AND "public"."user_assigned_to_order"("order_id")));



CREATE POLICY "Packers can insert packages for own maintenance survey orders" ON "public"."order_packages" FOR INSERT TO "authenticated" WITH CHECK ((("public"."get_user_role"() = 'packer'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_packages"."order_id") AND ("o"."created_by" = "auth"."uid"()) AND ("o"."project_type" = ANY (ARRAY['maintenance'::"public"."project_type", 'survey'::"public"."project_type"])))))));



CREATE POLICY "Packers can insert pending materials" ON "public"."materials" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("pending_approval" = true) AND ("approval_status" = 'pending'::"text")));



CREATE POLICY "Packers can insert pending pricing" ON "public"."supplier_pricing" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("pending_approval" = true) AND ("approval_status" = 'pending'::"text")));



CREATE POLICY "Packers can insert pending variants" ON "public"."material_variants" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("pending_approval" = true) AND ("approval_status" = 'pending'::"text")));



CREATE POLICY "Packers can read all order_packages for scanning" ON "public"."order_packages" FOR SELECT USING (("public"."get_user_role"() = 'packer'::"text"));



CREATE POLICY "Packers can read all orders for scanning" ON "public"."orders" FOR SELECT USING (("public"."get_user_role"() = 'packer'::"text"));



CREATE POLICY "Packers can read assigned order_packages" ON "public"."order_packages" FOR SELECT USING ((("public"."get_user_role"() = 'packer'::"text") AND "public"."user_assigned_to_order"("order_id")));



CREATE POLICY "Packers can read assigned orders" ON "public"."orders" FOR SELECT USING ((("public"."get_user_role"() = 'packer'::"text") AND "public"."user_assigned_to_order"("id")));



CREATE POLICY "Packers can read own maintenance survey orders" ON "public"."orders" FOR SELECT TO "authenticated" USING ((("public"."get_user_role"() = 'packer'::"text") AND ("created_by" = "auth"."uid"()) AND ("project_type" = ANY (ARRAY['maintenance'::"public"."project_type", 'survey'::"public"."project_type"]))));



CREATE POLICY "Packers can read packages for own maintenance survey orders" ON "public"."order_packages" FOR SELECT TO "authenticated" USING ((("public"."get_user_role"() = 'packer'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_packages"."order_id") AND ("o"."created_by" = "auth"."uid"()) AND ("o"."project_type" = ANY (ARRAY['maintenance'::"public"."project_type", 'survey'::"public"."project_type"])))))));



CREATE POLICY "Packers can see available orders for selection" ON "public"."orders" FOR SELECT USING ((("public"."get_user_role"() = 'packer'::"text") AND ("production_status" = ANY (ARRAY['pending'::"text", 'in_progress'::"text", 'on_hold'::"text"])) AND ("commercial_status" = 'approved'::"text")));



CREATE POLICY "Packers can update any order" ON "public"."orders" FOR UPDATE USING (("public"."get_user_role"() = 'packer'::"text")) WITH CHECK (("public"."get_user_role"() = 'packer'::"text"));



CREATE POLICY "Packers can update assigned order_packages" ON "public"."order_packages" FOR UPDATE USING ((("public"."get_user_role"() = 'packer'::"text") AND "public"."user_assigned_to_order"("order_id")));



CREATE POLICY "Packers can update packages for own maintenance survey orders" ON "public"."order_packages" FOR UPDATE TO "authenticated" USING ((("public"."get_user_role"() = 'packer'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_packages"."order_id") AND ("o"."created_by" = "auth"."uid"()) AND ("o"."project_type" = ANY (ARRAY['maintenance'::"public"."project_type", 'survey'::"public"."project_type"]))))))) WITH CHECK ((("public"."get_user_role"() = 'packer'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_packages"."order_id") AND ("o"."created_by" = "auth"."uid"()) AND ("o"."project_type" = ANY (ARRAY['maintenance'::"public"."project_type", 'survey'::"public"."project_type"])))))));



CREATE POLICY "Packers can view their own attendance" ON "public"."attendance_logs" FOR SELECT TO "authenticated" USING (("packer_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Packers can view their own sessions" ON "public"."packer_sessions" FOR SELECT TO "authenticated" USING (("packer_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Privileged users can manage profiles" ON "public"."profiles" FOR UPDATE USING ((("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])) OR ("public"."user_has_permission"('can_block_users'::"text") AND ("public"."get_user_role"() = 'project_lead'::"text"))));



CREATE POLICY "Read own and public signatures" ON "public"."signatures" FOR SELECT USING ((("is_public" = true) OR ("user_id" = "auth"."uid"())));



CREATE POLICY "Simple attendance access" ON "public"."attendance_logs" USING ((EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text", 'project_lead'::"text"])) AND ("p"."status" = 'active'::"text")))));



CREATE POLICY "Staff and packers can read all profiles" ON "public"."profiles" FOR SELECT USING ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers can read clients" ON "public"."clients" FOR SELECT USING ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers can read material_variant_tags" ON "public"."material_variant_tags" FOR SELECT USING ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers can read material_variants" ON "public"."material_variants" FOR SELECT USING ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers can read materials" ON "public"."materials" FOR SELECT USING ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers can read supplier_pricing" ON "public"."supplier_pricing" FOR SELECT USING ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage beam" ON "public"."beam" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage box_type" ON "public"."box_type" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage items_db" ON "public"."items_db" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage media" ON "public"."media" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage order_item_allocation" ON "public"."order_item_allocation" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage order_package_materials" ON "public"."order_package_materials" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage order_package_securing" ON "public"."order_package_securing" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage order_pkg_instance" ON "public"."order_pkg_instance" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage order_pkg_overview" ON "public"."order_pkg_overview" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage package_info" ON "public"."package_info" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage pkd_item" ON "public"."pkd_item" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage pkg_category" ON "public"."pkg_category" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff and packers manage securing_template" ON "public"."securing_template" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "Staff manage destinations" ON "public"."destinations" USING ("public"."is_staff_or_packer"()) WITH CHECK ("public"."is_staff_or_packer"());



CREATE POLICY "System can insert audit_log" ON "public"."audit_log" FOR INSERT WITH CHECK (true);



CREATE POLICY "Temporary all authenticated access" ON "public"."packer_sessions" USING ((( SELECT "auth"."uid"() AS "uid") IS NOT NULL));



CREATE POLICY "Update own signature" ON "public"."signatures" FOR UPDATE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own profile" ON "public"."profiles" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "id"));



CREATE POLICY "Users can update own profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (((( SELECT "auth"."uid"() AS "uid") IS NOT NULL) AND (( SELECT "auth"."uid"() AS "uid") = "id"))) WITH CHECK (((( SELECT "auth"."uid"() AS "uid") IS NOT NULL) AND (( SELECT "auth"."uid"() AS "uid") = "id")));



CREATE POLICY "Users can view temporary privileges" ON "public"."temporary_privileges" FOR SELECT USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM ("public"."profiles" "p"
     JOIN "public"."roles" "r" ON (("p"."role_id" = "r"."id")))
  WHERE (("p"."id" = "auth"."uid"()) AND ("r"."name" = ANY (ARRAY['admin'::"text", 'director'::"text"])))))));



CREATE POLICY "Users with manage_roles permission can modify roles" ON "public"."roles" USING ("public"."user_has_permission"('can_manage_roles'::"text"));



ALTER TABLE "public"."allocation_increase_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."attendance_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."audit_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "authenticated_full_access" ON "public"."allocation_increase_requests" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."app_settings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."category_order_map" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."client_order" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."client_quality_control" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."client_report" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."client_report_collaborators" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."client_report_orders" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."client_shipment" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."instance_c_report_map" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."material_requests" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."material_variant_requests" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."report_batch" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."report_template_settings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."request_audit_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."sei_categories" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."sei_protection" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."supplier_email_messages" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."supplier_pricing_requests" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."beam" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."box_type" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."category_order_map" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."category_tag_map" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_order" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_portal_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_quality_control" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_report" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_report_collaborators" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_report_orders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_shipment" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."clients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."destinations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."import_taqa3_catalog" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."instance_c_report_map" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."items_db" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."maintenance_task_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "maintenance_task_assignments_delete_authenticated" ON "public"."maintenance_task_assignments" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "maintenance_task_assignments_insert_authenticated" ON "public"."maintenance_task_assignments" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "maintenance_task_assignments_select_authenticated" ON "public"."maintenance_task_assignments" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "maintenance_task_assignments_update_authenticated" ON "public"."maintenance_task_assignments" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."maintenance_task_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "maintenance_task_log_insert_authenticated" ON "public"."maintenance_task_log" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "maintenance_task_log_select_authenticated" ON "public"."maintenance_task_log" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "maintenance_task_log_update_authenticated" ON "public"."maintenance_task_log" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."material_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."material_tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."material_variant_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."material_variant_tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."material_variants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."materials" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."media" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "mvt_delete_admin" ON "public"."material_variant_tags" FOR DELETE USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "mvt_insert_admin" ON "public"."material_variant_tags" FOR INSERT WITH CHECK (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



CREATE POLICY "mvt_update_admin" ON "public"."material_variant_tags" FOR UPDATE USING (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"]))) WITH CHECK (("public"."get_user_role"() = ANY (ARRAY['admin'::"text", 'director'::"text"])));



ALTER TABLE "public"."order_item_allocation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_package_materials" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_package_securing" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_package_services" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_packages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_pkg_instance" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_pkg_overview" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."order_team_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."orders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."package_info" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."package_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."packer_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."packing_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pkd_item" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pkg_category" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."qr_codes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."report_batch" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."report_template_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."request_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."securing_template" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sei_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sei_protection" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."services" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."signatures" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."supplier_email_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."supplier_pricing" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."supplier_pricing_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."suppliers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "task_assignments_insert_authenticated" ON "public"."task_assignments" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "task_assignments_select_authenticated" ON "public"."task_assignments" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "task_assignments_update_authenticated" ON "public"."task_assignments" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."task_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "task_logs_insert_authenticated" ON "public"."task_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "task_logs_select_authenticated" ON "public"."task_logs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "task_logs_update_authenticated" ON "public"."task_logs" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."task_packages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "task_packages_insert_authenticated" ON "public"."task_packages" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "task_packages_select_authenticated" ON "public"."task_packages" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."tasks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."temporary_privileges" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transportation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."units_of_measure" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."add_order_item_allocation"("p_order_id" "uuid", "p_items_db_id" "uuid", "p_destination_id" "uuid", "p_expected" numeric, "p_is_standard_box" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."add_order_item_allocation"("p_order_id" "uuid", "p_items_db_id" "uuid", "p_destination_id" "uuid", "p_expected" numeric, "p_is_standard_box" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_order_item_allocation"("p_order_id" "uuid", "p_items_db_id" "uuid", "p_destination_id" "uuid", "p_expected" numeric, "p_is_standard_box" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."add_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."add_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_force_release_packer"("packer_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_force_release_packer"("packer_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_force_release_packer"("packer_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_order_item_allocations"("p_order_id" "uuid", "p_allocations" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."apply_order_item_allocations"("p_order_id" "uuid", "p_allocations" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_order_item_allocations"("p_order_id" "uuid", "p_allocations" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_allocation_increase_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text", "p_granted_delta" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."approve_allocation_increase_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text", "p_granted_delta" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_allocation_increase_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text", "p_granted_delta" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_material_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_material_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_material_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_material_variant_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_material_variant_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_material_variant_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_supplier_pricing_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_supplier_pricing_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_supplier_pricing_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."assign_packers_to_order"("order_uuid" "uuid", "packer_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."assign_packers_to_order"("order_uuid" "uuid", "packer_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_packers_to_order"("order_uuid" "uuid", "packer_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."assign_report_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."assign_report_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_report_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."assign_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."assign_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_be_project_lead"("user_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_be_project_lead"("user_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_be_project_lead"("user_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_record_attendance"("order_uuid" "uuid", "packer_uuid" "uuid", "shift_period_param" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."can_record_attendance"("order_uuid" "uuid", "packer_uuid" "uuid", "shift_period_param" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_record_attendance"("order_uuid" "uuid", "packer_uuid" "uuid", "shift_period_param" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_resume_task"("task_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_resume_task"("task_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_resume_task"("task_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_user_mark_attendance"("order_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_user_mark_attendance"("order_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_user_mark_attendance"("order_uuid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cleanup_order_pkg_instance_qr"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_order_pkg_instance_qr"() TO "service_role";



GRANT ALL ON FUNCTION "public"."complete_assignments_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."complete_assignments_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_assignments_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."complete_task"("task_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."complete_task"("task_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_task"("task_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."count_order_team_leads"("order_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."count_order_team_leads"("order_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."count_order_team_leads"("order_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."current_client_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_client_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_client_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."deactivate_expired_privileges"() TO "anon";
GRANT ALL ON FUNCTION "public"."deactivate_expired_privileges"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."deactivate_expired_privileges"() TO "service_role";



GRANT ALL ON FUNCTION "public"."debug_user_info"() TO "anon";
GRANT ALL ON FUNCTION "public"."debug_user_info"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."debug_user_info"() TO "service_role";



GRANT ALL ON FUNCTION "public"."decrement_item_packed_qty"("item_id" "uuid", "amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."decrement_item_packed_qty"("item_id" "uuid", "amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."decrement_item_packed_qty"("item_id" "uuid", "amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_order_cascade"("order_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_order_cascade"("order_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_order_cascade"("order_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_tasks_for_order_packages"("package_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."delete_tasks_for_order_packages"("package_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_tasks_for_order_packages"("package_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."enforce_single_active_order_for_packer"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_single_active_order_for_packer"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_single_active_order_for_packer"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."ensure_order_pkg_instance_qr"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_order_pkg_instance_qr"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fetch_instance_items"("p_instance_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."fetch_instance_items"("p_instance_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fetch_instance_items"("p_instance_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_id" "uuid", "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_id" "uuid", "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_id" "uuid", "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean, "p_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean, "p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean, "p_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean, "p_order_id" "uuid", "p_tag_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean, "p_order_id" "uuid", "p_tag_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fetch_report_instances"("p_client_id" "uuid", "p_order_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_date_mode" "text", "p_destinations" "text"[], "p_has_items_only" boolean, "p_order_id" "uuid", "p_tag_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_active_tasks_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_active_tasks_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_active_tasks_for_packers"("order_uuid" "uuid", "packer_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_all_packers_with_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_all_packers_with_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_all_packers_with_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_available_packers"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_available_packers"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_available_packers"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_busy_packers"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_busy_packers"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_busy_packers"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_order_packers"("order_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_order_packers"("order_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_order_packers"("order_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_order_progress"("order_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_order_progress"("order_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_order_progress"("order_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_order_team_leads"("order_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_order_team_leads"("order_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_order_team_leads"("order_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_packer_assignment_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_packer_assignment_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_packer_assignment_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_email_by_username"("lookup_username" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_email_by_username"("lookup_username" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_email_by_username"("lookup_username" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."guard_profile_security_fields"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."guard_profile_security_fields"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_empty_order"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_empty_order"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_empty_order"() TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_item_packed_qty"("item_id" "uuid", "amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."increment_item_packed_qty"("item_id" "uuid", "amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_item_packed_qty"("item_id" "uuid", "amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."is_my_client_instance"("p_instance_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_my_client_instance"("p_instance_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_my_client_instance"("p_instance_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_my_client_order"("p_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_my_client_order"("p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_my_client_order"("p_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_my_client_package"("p_pkg_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_my_client_package"("p_pkg_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_my_client_package"("p_pkg_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_staff_or_packer"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_staff_or_packer"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_staff_or_packer"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_team_lead_for_order"("user_id" "uuid", "order_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_team_lead_for_order"("user_id" "uuid", "order_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_team_lead_for_order"("user_id" "uuid", "order_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."log_packer_status_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."log_packer_status_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_packer_status_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."mark_order_package_packed"("op_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."mark_order_package_packed"("op_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_order_package_packed"("op_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."order_has_team_lead"("order_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."order_has_team_lead"("order_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."order_has_team_lead"("order_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."packer_logged_attendance_today"("order_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."packer_logged_attendance_today"("order_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."packer_logged_attendance_today"("order_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."packer_needs_daily_attendance"("packer_uuid" "uuid", "order_uuid" "uuid", "check_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."packer_needs_daily_attendance"("packer_uuid" "uuid", "order_uuid" "uuid", "check_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."packer_needs_daily_attendance"("packer_uuid" "uuid", "order_uuid" "uuid", "check_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."pause_task"("task_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."pause_task"("task_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."pause_task"("task_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_alloc_packed"("p_item" "uuid", "p_instance" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_alloc_packed"("p_item" "uuid", "p_instance" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_alloc_packed"("p_item" "uuid", "p_instance" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_alloc_packed_key"("p_order" "uuid", "p_item" "uuid", "p_dest_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_alloc_packed_key"("p_order" "uuid", "p_item" "uuid", "p_dest_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_alloc_packed_key"("p_order" "uuid", "p_item" "uuid", "p_dest_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_order_pkg_overview_rollup"("p_overview_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_order_pkg_overview_rollup"("p_overview_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_order_pkg_overview_rollup"("p_overview_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_allocation_increase_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_allocation_increase_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_allocation_increase_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_material_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_material_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_material_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_material_variant_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_material_variant_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_material_variant_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_supplier_pricing_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_supplier_pricing_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_supplier_pricing_request"("p_request_id" "uuid", "p_reviewed_by" "uuid", "p_admin_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."remove_self_from_order"("order_uuid" "uuid", "packer_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."remove_self_from_order"("order_uuid" "uuid", "packer_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_self_from_order"("order_uuid" "uuid", "packer_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."remove_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."remove_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_team_lead"("order_uuid" "uuid", "packer_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."resume_task"("task_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."resume_task"("task_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resume_task"("task_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_allocation_expected"("p_allocation_id" "uuid", "p_expected" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."set_allocation_expected"("p_allocation_id" "uuid", "p_expected" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_allocation_expected"("p_allocation_id" "uuid", "p_expected" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_maintenance_task_assignments_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_maintenance_task_assignments_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_maintenance_task_assignments_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_maintenance_task_log_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_maintenance_task_log_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_maintenance_task_log_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_order_pkg_instance_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_order_pkg_instance_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_order_pkg_instance_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_order_pkg_overview_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_order_pkg_overview_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_order_pkg_overview_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."stamp_instance_packed_at_on_package_packed"() TO "anon";
GRANT ALL ON FUNCTION "public"."stamp_instance_packed_at_on_package_packed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."stamp_instance_packed_at_on_package_packed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_profile_on_order_team_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_profile_on_order_team_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_profile_on_order_team_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_instance_destination_packed_sync"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_instance_destination_packed_sync"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_instance_destination_packed_sync"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_order_pkg_instance_rollup"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_order_pkg_instance_rollup"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_order_pkg_instance_rollup"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_pkd_item_packed_sync"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_pkd_item_packed_sync"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_pkd_item_packed_sync"() TO "service_role";



GRANT ALL ON FUNCTION "public"."unpack_order_package"("op_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."unpack_order_package"("op_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unpack_order_package"("op_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."unpause_task"("task_log_id" "uuid", "pause_duration_seconds" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."unpause_task"("task_log_id" "uuid", "pause_duration_seconds" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."unpause_task"("task_log_id" "uuid", "pause_duration_seconds" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_app_settings_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_app_settings_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_app_settings_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_packer_status_on_assignment"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_packer_status_on_assignment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_packer_status_on_assignment"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_packer_status_on_order_completion"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_packer_status_on_order_completion"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_packer_status_on_order_completion"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_pending_material_additions_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_pending_material_additions_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_pending_material_additions_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_project_lead_with_status"("order_uuid" "uuid", "lead_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."update_project_lead_with_status"("order_uuid" "uuid", "lead_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_project_lead_with_status"("order_uuid" "uuid", "lead_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_order_item_allocation"("p_order_id" "uuid", "p_items_db_id" "uuid", "p_destination_id" "uuid", "p_expected" numeric, "p_is_standard_box" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_order_item_allocation"("p_order_id" "uuid", "p_items_db_id" "uuid", "p_destination_id" "uuid", "p_expected" numeric, "p_is_standard_box" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_order_item_allocation"("p_order_id" "uuid", "p_items_db_id" "uuid", "p_destination_id" "uuid", "p_expected" numeric, "p_is_standard_box" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."user_assigned_to_order"("order_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."user_assigned_to_order"("order_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_assigned_to_order"("order_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."user_has_permission"("permission_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."user_has_permission"("permission_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_has_permission"("permission_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_box_completion"("op_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."validate_box_completion"("op_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_box_completion"("op_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."allocation_increase_requests" TO "anon";
GRANT ALL ON TABLE "public"."allocation_increase_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."allocation_increase_requests" TO "service_role";



GRANT ALL ON TABLE "public"."app_settings" TO "anon";
GRANT ALL ON TABLE "public"."app_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."app_settings" TO "service_role";



GRANT ALL ON TABLE "public"."attendance_logs" TO "anon";
GRANT ALL ON TABLE "public"."attendance_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."attendance_logs" TO "service_role";



GRANT ALL ON TABLE "public"."audit_log" TO "anon";
GRANT ALL ON TABLE "public"."audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."beam" TO "anon";
GRANT ALL ON TABLE "public"."beam" TO "authenticated";
GRANT ALL ON TABLE "public"."beam" TO "service_role";



GRANT ALL ON TABLE "public"."box_type" TO "anon";
GRANT ALL ON TABLE "public"."box_type" TO "authenticated";
GRANT ALL ON TABLE "public"."box_type" TO "service_role";



GRANT ALL ON TABLE "public"."category_order_map" TO "anon";
GRANT ALL ON TABLE "public"."category_order_map" TO "authenticated";
GRANT ALL ON TABLE "public"."category_order_map" TO "service_role";



GRANT ALL ON TABLE "public"."category_tag_map" TO "anon";
GRANT ALL ON TABLE "public"."category_tag_map" TO "authenticated";
GRANT ALL ON TABLE "public"."category_tag_map" TO "service_role";



GRANT ALL ON TABLE "public"."client_order" TO "anon";
GRANT ALL ON TABLE "public"."client_order" TO "authenticated";
GRANT ALL ON TABLE "public"."client_order" TO "service_role";



GRANT ALL ON TABLE "public"."client_portal_settings" TO "anon";
GRANT ALL ON TABLE "public"."client_portal_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."client_portal_settings" TO "service_role";



GRANT ALL ON TABLE "public"."client_quality_control" TO "anon";
GRANT ALL ON TABLE "public"."client_quality_control" TO "authenticated";
GRANT ALL ON TABLE "public"."client_quality_control" TO "service_role";



GRANT ALL ON TABLE "public"."client_report" TO "anon";
GRANT ALL ON TABLE "public"."client_report" TO "authenticated";
GRANT ALL ON TABLE "public"."client_report" TO "service_role";



GRANT ALL ON TABLE "public"."client_report_collaborators" TO "anon";
GRANT ALL ON TABLE "public"."client_report_collaborators" TO "authenticated";
GRANT ALL ON TABLE "public"."client_report_collaborators" TO "service_role";



GRANT ALL ON TABLE "public"."client_report_orders" TO "anon";
GRANT ALL ON TABLE "public"."client_report_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."client_report_orders" TO "service_role";



GRANT ALL ON TABLE "public"."client_shipment" TO "anon";
GRANT ALL ON TABLE "public"."client_shipment" TO "authenticated";
GRANT ALL ON TABLE "public"."client_shipment" TO "service_role";



GRANT ALL ON TABLE "public"."clients" TO "anon";
GRANT ALL ON TABLE "public"."clients" TO "authenticated";
GRANT ALL ON TABLE "public"."clients" TO "service_role";



GRANT ALL ON TABLE "public"."destinations" TO "anon";
GRANT ALL ON TABLE "public"."destinations" TO "authenticated";
GRANT ALL ON TABLE "public"."destinations" TO "service_role";



GRANT ALL ON TABLE "public"."import_taqa3_catalog" TO "anon";
GRANT ALL ON TABLE "public"."import_taqa3_catalog" TO "authenticated";
GRANT ALL ON TABLE "public"."import_taqa3_catalog" TO "service_role";



GRANT ALL ON TABLE "public"."instance_c_report_map" TO "anon";
GRANT ALL ON TABLE "public"."instance_c_report_map" TO "authenticated";
GRANT ALL ON TABLE "public"."instance_c_report_map" TO "service_role";



GRANT ALL ON TABLE "public"."items_db" TO "anon";
GRANT ALL ON TABLE "public"."items_db" TO "authenticated";
GRANT ALL ON TABLE "public"."items_db" TO "service_role";



GRANT ALL ON TABLE "public"."maintenance_task_assignments" TO "anon";
GRANT ALL ON TABLE "public"."maintenance_task_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."maintenance_task_assignments" TO "service_role";



GRANT ALL ON TABLE "public"."maintenance_task_log" TO "anon";
GRANT ALL ON TABLE "public"."maintenance_task_log" TO "authenticated";
GRANT ALL ON TABLE "public"."maintenance_task_log" TO "service_role";



GRANT ALL ON TABLE "public"."material_requests" TO "anon";
GRANT ALL ON TABLE "public"."material_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."material_requests" TO "service_role";



GRANT ALL ON TABLE "public"."material_tags" TO "anon";
GRANT ALL ON TABLE "public"."material_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."material_tags" TO "service_role";



GRANT ALL ON TABLE "public"."material_variant_requests" TO "anon";
GRANT ALL ON TABLE "public"."material_variant_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."material_variant_requests" TO "service_role";



GRANT ALL ON TABLE "public"."material_variant_tags" TO "anon";
GRANT ALL ON TABLE "public"."material_variant_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."material_variant_tags" TO "service_role";



GRANT ALL ON TABLE "public"."material_variants" TO "anon";
GRANT ALL ON TABLE "public"."material_variants" TO "authenticated";
GRANT ALL ON TABLE "public"."material_variants" TO "service_role";



GRANT ALL ON TABLE "public"."materials" TO "anon";
GRANT ALL ON TABLE "public"."materials" TO "authenticated";
GRANT ALL ON TABLE "public"."materials" TO "service_role";



GRANT ALL ON TABLE "public"."media" TO "anon";
GRANT ALL ON TABLE "public"."media" TO "authenticated";
GRANT ALL ON TABLE "public"."media" TO "service_role";



GRANT ALL ON TABLE "public"."order_item_allocation" TO "anon";
GRANT ALL ON TABLE "public"."order_item_allocation" TO "authenticated";
GRANT ALL ON TABLE "public"."order_item_allocation" TO "service_role";



GRANT ALL ON TABLE "public"."order_package_materials" TO "anon";
GRANT ALL ON TABLE "public"."order_package_materials" TO "authenticated";
GRANT ALL ON TABLE "public"."order_package_materials" TO "service_role";



GRANT ALL ON TABLE "public"."order_package_securing" TO "anon";
GRANT ALL ON TABLE "public"."order_package_securing" TO "authenticated";
GRANT ALL ON TABLE "public"."order_package_securing" TO "service_role";



GRANT ALL ON TABLE "public"."order_package_services" TO "anon";
GRANT ALL ON TABLE "public"."order_package_services" TO "authenticated";
GRANT ALL ON TABLE "public"."order_package_services" TO "service_role";



GRANT ALL ON TABLE "public"."order_packages" TO "anon";
GRANT ALL ON TABLE "public"."order_packages" TO "authenticated";
GRANT ALL ON TABLE "public"."order_packages" TO "service_role";



GRANT ALL ON TABLE "public"."order_pkg_instance" TO "anon";
GRANT ALL ON TABLE "public"."order_pkg_instance" TO "authenticated";
GRANT ALL ON TABLE "public"."order_pkg_instance" TO "service_role";



GRANT ALL ON TABLE "public"."order_pkg_overview" TO "anon";
GRANT ALL ON TABLE "public"."order_pkg_overview" TO "authenticated";
GRANT ALL ON TABLE "public"."order_pkg_overview" TO "service_role";



GRANT ALL ON TABLE "public"."order_team_members" TO "anon";
GRANT ALL ON TABLE "public"."order_team_members" TO "authenticated";
GRANT ALL ON TABLE "public"."order_team_members" TO "service_role";



GRANT ALL ON TABLE "public"."orders" TO "anon";
GRANT ALL ON TABLE "public"."orders" TO "authenticated";
GRANT ALL ON TABLE "public"."orders" TO "service_role";



GRANT ALL ON TABLE "public"."package_info" TO "anon";
GRANT ALL ON TABLE "public"."package_info" TO "authenticated";
GRANT ALL ON TABLE "public"."package_info" TO "service_role";



GRANT ALL ON TABLE "public"."package_items" TO "anon";
GRANT ALL ON TABLE "public"."package_items" TO "authenticated";
GRANT ALL ON TABLE "public"."package_items" TO "service_role";



GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";



GRANT ALL ON TABLE "public"."packer_availability_status" TO "anon";
GRANT ALL ON TABLE "public"."packer_availability_status" TO "authenticated";
GRANT ALL ON TABLE "public"."packer_availability_status" TO "service_role";



GRANT ALL ON TABLE "public"."packer_sessions" TO "anon";
GRANT ALL ON TABLE "public"."packer_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."packer_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."packing_types" TO "anon";
GRANT ALL ON TABLE "public"."packing_types" TO "authenticated";
GRANT ALL ON TABLE "public"."packing_types" TO "service_role";



GRANT ALL ON TABLE "public"."pkd_item" TO "anon";
GRANT ALL ON TABLE "public"."pkd_item" TO "authenticated";
GRANT ALL ON TABLE "public"."pkd_item" TO "service_role";



GRANT ALL ON TABLE "public"."pkg_category" TO "anon";
GRANT ALL ON TABLE "public"."pkg_category" TO "authenticated";
GRANT ALL ON TABLE "public"."pkg_category" TO "service_role";



GRANT ALL ON TABLE "public"."project_tags" TO "anon";
GRANT ALL ON TABLE "public"."project_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."project_tags" TO "service_role";



GRANT ALL ON TABLE "public"."qr_codes" TO "anon";
GRANT ALL ON TABLE "public"."qr_codes" TO "authenticated";
GRANT ALL ON TABLE "public"."qr_codes" TO "service_role";



GRANT ALL ON TABLE "public"."report_batch" TO "anon";
GRANT ALL ON TABLE "public"."report_batch" TO "authenticated";
GRANT ALL ON TABLE "public"."report_batch" TO "service_role";



GRANT ALL ON SEQUENCE "public"."report_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."report_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."report_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."report_template_settings" TO "anon";
GRANT ALL ON TABLE "public"."report_template_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."report_template_settings" TO "service_role";



GRANT ALL ON TABLE "public"."request_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."request_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."request_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."securing_template" TO "anon";
GRANT ALL ON TABLE "public"."securing_template" TO "authenticated";
GRANT ALL ON TABLE "public"."securing_template" TO "service_role";



GRANT ALL ON TABLE "public"."sei_categories" TO "anon";
GRANT ALL ON TABLE "public"."sei_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."sei_categories" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sei_categories_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sei_categories_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sei_categories_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sei_protection" TO "anon";
GRANT ALL ON TABLE "public"."sei_protection" TO "authenticated";
GRANT ALL ON TABLE "public"."sei_protection" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sei_protection_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sei_protection_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sei_protection_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."services" TO "anon";
GRANT ALL ON TABLE "public"."services" TO "authenticated";
GRANT ALL ON TABLE "public"."services" TO "service_role";



GRANT ALL ON TABLE "public"."signatures" TO "anon";
GRANT ALL ON TABLE "public"."signatures" TO "authenticated";
GRANT ALL ON TABLE "public"."signatures" TO "service_role";



GRANT ALL ON TABLE "public"."supplier_email_messages" TO "anon";
GRANT ALL ON TABLE "public"."supplier_email_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."supplier_email_messages" TO "service_role";



GRANT ALL ON TABLE "public"."supplier_pricing" TO "anon";
GRANT ALL ON TABLE "public"."supplier_pricing" TO "authenticated";
GRANT ALL ON TABLE "public"."supplier_pricing" TO "service_role";



GRANT ALL ON TABLE "public"."supplier_pricing_requests" TO "anon";
GRANT ALL ON TABLE "public"."supplier_pricing_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."supplier_pricing_requests" TO "service_role";



GRANT ALL ON TABLE "public"."suppliers" TO "anon";
GRANT ALL ON TABLE "public"."suppliers" TO "authenticated";
GRANT ALL ON TABLE "public"."suppliers" TO "service_role";



GRANT ALL ON TABLE "public"."tags" TO "anon";
GRANT ALL ON TABLE "public"."tags" TO "authenticated";
GRANT ALL ON TABLE "public"."tags" TO "service_role";



GRANT ALL ON TABLE "public"."task_assignments" TO "anon";
GRANT ALL ON TABLE "public"."task_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."task_assignments" TO "service_role";



GRANT ALL ON TABLE "public"."task_logs" TO "anon";
GRANT ALL ON TABLE "public"."task_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."task_logs" TO "service_role";



GRANT ALL ON TABLE "public"."task_packages" TO "anon";
GRANT ALL ON TABLE "public"."task_packages" TO "authenticated";
GRANT ALL ON TABLE "public"."task_packages" TO "service_role";



GRANT ALL ON TABLE "public"."tasks" TO "anon";
GRANT ALL ON TABLE "public"."tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."tasks" TO "service_role";



GRANT ALL ON TABLE "public"."task_status_view" TO "anon";
GRANT ALL ON TABLE "public"."task_status_view" TO "authenticated";
GRANT ALL ON TABLE "public"."task_status_view" TO "service_role";



GRANT ALL ON TABLE "public"."temporary_privileges" TO "anon";
GRANT ALL ON TABLE "public"."temporary_privileges" TO "authenticated";
GRANT ALL ON TABLE "public"."temporary_privileges" TO "service_role";



GRANT ALL ON TABLE "public"."transportation" TO "anon";
GRANT ALL ON TABLE "public"."transportation" TO "authenticated";
GRANT ALL ON TABLE "public"."transportation" TO "service_role";



GRANT ALL ON TABLE "public"."units_of_measure" TO "anon";
GRANT ALL ON TABLE "public"."units_of_measure" TO "authenticated";
GRANT ALL ON TABLE "public"."units_of_measure" TO "service_role";



GRANT ALL ON TABLE "public"."user_effective_permissions" TO "anon";
GRANT ALL ON TABLE "public"."user_effective_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."user_effective_permissions" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






