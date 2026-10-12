-- =====================================================================
--  Brixly Beer Game — ติดตั้งฐานข้อมูลบน Supabase (ทำครั้งเดียว)
--  1) สร้างโปรเจกต์ฟรีที่ supabase.com
--  2) เมนู SQL Editor → New query → วางไฟล์นี้ทั้งไฟล์ → Run
--  3) เมนู Project Settings → API → คัดลอก Project URL และ anon public key
--     ไปใส่ในไฟล์ brixly-beer-game.html (SUPABASE_URL / SUPABASE_ANON_KEY)
--  รันซ้ำได้ แต่ข้อมูลเกมเดิมทั้งหมดจะถูกล้าง
-- =====================================================================
DO $$ DECLARE f record; BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
           WHERE n.nspname='public' AND p.proname LIKE 'bg\_%' LOOP
    EXECUTE 'DROP FUNCTION ' || f.sig || ' CASCADE';
  END LOOP;
END $$;
-- =====================================================================
-- Brixly Supply Chain Simulation Lab — authoritative game engine + API
-- PostgreSQL 15+ (Supabase-compatible).
--
-- SECURITY MODEL
--   * All tables live in schema `lab`. Client roles (`anon`, Supabase
--     `authenticated`) get NO privileges on schema `lab` at all.
--   * Clients can only call SECURITY DEFINER functions in schema `api`.
--     Each function authenticates a bearer token (player / teacher /
--     projector) and returns ONLY the fields that caller may see.
--   * Therefore Round-1 customer demand is never sent to an unauthorized
--     client — it is not hidden by the UI, it is never in the payload.
--
-- CONCURRENCY MODEL
--   * One `orders` row per (round, team, role, week): PK makes double
--     submits impossible; four roles never share a row (no overwrites).
--   * advance_week(expected_week) locks the round row FOR UPDATE and is a
--     no-op unless current_week = expected_week → double-click safe.
--   * submit_order locks the round row FOR SHARE, so a submit can never
--     interleave with a week being processed.
-- =====================================================================
DROP SCHEMA IF EXISTS lab CASCADE;
CREATE SCHEMA lab;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- --------------------------------------------------------------- tables
CREATE TABLE lab.rooms (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code            text UNIQUE NOT NULL,
  teacher_token   uuid NOT NULL DEFAULT gen_random_uuid(),
  projector_token uuid NOT NULL DEFAULT gen_random_uuid(),
  is_demo         boolean NOT NULL DEFAULT false,
  demand_locked   boolean NOT NULL DEFAULT false,
  config          jsonb NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE lab.demand_template (           -- teacher-editable until Round 1 starts
  room_id uuid REFERENCES lab.rooms ON DELETE CASCADE,
  round_kind text CHECK (round_kind IN ('BASE','SHOCK')),
  week int CHECK (week >= 1),
  qty int NOT NULL CHECK (qty >= 0),
  PRIMARY KEY (room_id, round_kind, week)
);

CREATE TABLE lab.players (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id     uuid NOT NULL REFERENCES lab.rooms ON DELETE CASCADE,
  token       uuid UNIQUE NOT NULL DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  student_code text,
  is_teacher  boolean NOT NULL DEFAULT false,
  rejoin_pin  text,
  last_seen   timestamptz NOT NULL DEFAULT now(),
  joined_at   timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE lab.seats (                     -- the SEAT owns decisions; players can be swapped
  room_id   uuid REFERENCES lab.rooms ON DELETE CASCADE,
  team_no   int  CHECK (team_no >= 1),
  role      text CHECK (role IN ('retailer','distributor','manufacturer','supplier')),
  player_id uuid UNIQUE REFERENCES lab.players ON DELETE SET NULL,
  PRIMARY KEY (room_id, team_no, role)
);

CREATE TABLE lab.rounds (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id     uuid NOT NULL REFERENCES lab.rooms ON DELETE CASCADE,
  round_no    int  NOT NULL CHECK (round_no BETWEEN 1 AND 3),
  attempt     int  NOT NULL DEFAULT 1,
  active      boolean NOT NULL DEFAULT true,
  mode        text NOT NULL CHECK (mode IN ('SILO','SHARE','SHOCK')),
  status      text NOT NULL CHECK (status IN ('playing','paused','complete','revealed')),
  current_week int NOT NULL,
  weeks       int NOT NULL,
  lead_time   int NOT NULL CHECK (lead_time >= 1),
  shock_announced boolean NOT NULL DEFAULT false,
  shock_week  int,
  report      jsonb,          -- frozen at reveal: results never change after that, so every phone reads this copy
  started_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (room_id, round_no, attempt)
);
CREATE UNIQUE INDEX one_active_attempt ON lab.rounds(room_id, round_no) WHERE active;

CREATE TABLE lab.round_teams (round_id uuid REFERENCES lab.rounds ON DELETE CASCADE, team_no int,
  PRIMARY KEY (round_id, team_no));

CREATE TABLE lab.demand (                    -- TEACHER-ONLY. never exposed to students/projector during play
  round_id uuid REFERENCES lab.rounds ON DELETE CASCADE,
  week int, qty int NOT NULL CHECK (qty >= 0),
  PRIMARY KEY (round_id, week)
);

CREATE TABLE lab.stage_week (                -- audit record of every stage, every week (spec §30)
  round_id uuid REFERENCES lab.rounds ON DELETE CASCADE,
  team_no int, role text, week int,
  inv_before int NOT NULL, arrivals int NOT NULL, incoming_order int NOT NULL,
  backlog_before int NOT NULL, shipped int NOT NULL, on_time int NOT NULL,
  inv_after int NOT NULL CHECK (inv_after >= 0),
  backlog_after int NOT NULL CHECK (backlog_after >= 0),
  holding_cost numeric NOT NULL, backlog_cost numeric NOT NULL, expedite_cost numeric NOT NULL DEFAULT 0,
  computed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (round_id, team_no, role, week),
  CHECK (inv_after = inv_before + arrivals - shipped),
  CHECK (backlog_after = backlog_before + incoming_order - shipped),
  CHECK (shipped >= 0)
);

CREATE TABLE lab.pipeline (
  id bigserial PRIMARY KEY,
  round_id uuid REFERENCES lab.rounds ON DELETE CASCADE,
  team_no int, role text, arrival_week int, qty int CHECK (qty > 0),
  source text CHECK (source IN ('seed','shipment','production','expedite')),
  created_week int
);
CREATE INDEX ON lab.pipeline(round_id, team_no, role, arrival_week);

CREATE TABLE lab.orders (                    -- OPERATION decisions
  round_id uuid REFERENCES lab.rounds ON DELETE CASCADE,
  team_no int, role text, week int,
  qty int NOT NULL CHECK (qty >= 0),
  expedite int NOT NULL DEFAULT 0 CHECK (expedite >= 0),
  production_qty int CHECK (production_qty >= 0),
  shipment_priority text,
  submitted_by uuid REFERENCES lab.players ON DELETE SET NULL,
  auto_filled boolean NOT NULL DEFAULT false,
  edit_allowed boolean NOT NULL DEFAULT false,
  version int NOT NULL DEFAULT 1,
  submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (round_id, team_no, role, week)
);

CREATE TABLE lab.order_log (                 -- every attempt, including rejected duplicates and edits
  id bigserial PRIMARY KEY, round_id uuid, team_no int, role text, week int,
  qty int, expedite int, player_id uuid, outcome text, at timestamptz DEFAULT clock_timestamp()
);

CREATE TABLE lab.team_notes (round_id uuid REFERENCES lab.rounds ON DELETE CASCADE, team_no int,
  body text NOT NULL DEFAULT '', updated_by uuid, updated_at timestamptz DEFAULT now(),
  PRIMARY KEY (round_id, team_no));

CREATE TABLE lab.strategy_decisions (round_id uuid REFERENCES lab.rounds ON DELETE CASCADE, team_no int,
  priority text CHECK (priority IN ('EFFICIENT','RESPONSIVE','BALANCED')),
  accepted_risks text[] NOT NULL DEFAULT '{}', rationale text,
  submitted_by uuid, submitted_at timestamptz DEFAULT now(), PRIMARY KEY (round_id, team_no));

CREATE TABLE lab.planning_decisions (round_id uuid REFERENCES lab.rounds ON DELETE CASCADE, team_no int,
  safety_stock text, temporary_capacity text, supplier_preparation text,
  transportation_capacity text, demand_monitoring text, contingency_plan text,
  submitted_by uuid, submitted_at timestamptz DEFAULT now(), PRIMARY KEY (round_id, team_no));

CREATE TABLE lab.teacher_actions (id bigserial PRIMARY KEY, room_id uuid, action text, detail jsonb,
  outcome text, at timestamptz DEFAULT clock_timestamp());

-- --------------------------------------------------------------- helpers (private)
CREATE FUNCTION lab.roles() RETURNS text[] LANGUAGE sql IMMUTABLE AS
$$ SELECT ARRAY['retailer','distributor','manufacturer','supplier'] $$;

CREATE FUNCTION lab.ordered_by(r text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE r WHEN 'distributor' THEN 'retailer' WHEN 'manufacturer' THEN 'distributor'
                WHEN 'supplier' THEN 'manufacturer' END $$;
CREATE FUNCTION lab.ships_to(r text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE r WHEN 'distributor' THEN 'retailer' WHEN 'manufacturer' THEN 'distributor'
                WHEN 'supplier' THEN 'manufacturer' END $$;

CREATE FUNCTION lab.cfg(p_room uuid, k text) RETURNS numeric LANGUAGE sql STABLE AS
$$ SELECT (config->>k)::numeric FROM lab.rooms WHERE id = p_room $$;

CREATE FUNCTION lab.active_round(p_room uuid) RETURNS lab.rounds LANGUAGE sql STABLE AS $$
  SELECT * FROM lab.rounds WHERE room_id = p_room AND active ORDER BY round_no DESC LIMIT 1 $$;

CREATE FUNCTION lab.teacher_room(p_token uuid) RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE v uuid; BEGIN
  SELECT id INTO v FROM lab.rooms WHERE teacher_token = p_token;
  IF v IS NULL THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501'; END IF;
  RETURN v; END $$;

-- ---------------------------------------------------------------- ENGINE
-- Open week t for every team in the round (arrivals → incoming order → ship).
CREATE FUNCTION lab.open_week(p_round uuid, t int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE rd lab.rounds; tm int; r text; prev lab.stage_week; v_arr int; v_inc int;
        inv_b int; bl_b int; v_ship int; h numeric; b numeric; init_flow int; start_inv int;
BEGIN
  SELECT * INTO rd FROM lab.rounds WHERE id = p_round;
  h := lab.cfg(rd.room_id,'holding_cost'); b := lab.cfg(rd.room_id,'backorder_cost');
  init_flow := lab.cfg(rd.room_id,'init_flow'); start_inv := lab.cfg(rd.room_id,'start_inv');
  FOR tm IN SELECT team_no FROM lab.round_teams WHERE round_id = p_round ORDER BY team_no LOOP
    FOREACH r IN ARRAY lab.roles() LOOP
      SELECT * INTO prev FROM lab.stage_week WHERE round_id=p_round AND team_no=tm AND role=r AND week=t-1;
      inv_b := COALESCE(prev.inv_after, start_inv);
      bl_b  := COALESCE(prev.backlog_after, 0);
      SELECT COALESCE(sum(qty),0) INTO v_arr FROM lab.pipeline
        WHERE round_id=p_round AND team_no=tm AND role=r AND arrival_week=t;
      IF r = 'retailer' THEN
        SELECT qty INTO v_inc FROM lab.demand WHERE round_id=p_round AND week=t;
        IF v_inc IS NULL THEN RAISE EXCEPTION 'missing demand for week %', t; END IF;
      ELSIF t = 1 THEN
        v_inc := init_flow;                                  -- seeded week-0 order
      ELSE
        SELECT qty INTO v_inc FROM lab.orders
          WHERE round_id=p_round AND team_no=tm AND role=lab.ordered_by(r) AND week=t-1;
        IF v_inc IS NULL THEN RAISE EXCEPTION 'missing order % team % week %', lab.ordered_by(r), tm, t-1; END IF;
      END IF;
      v_ship := LEAST(inv_b + v_arr, bl_b + v_inc);
      INSERT INTO lab.stage_week(round_id,team_no,role,week,inv_before,arrivals,incoming_order,backlog_before,
                                 shipped,on_time,inv_after,backlog_after,holding_cost,backlog_cost)
      VALUES (p_round,tm,r,t,inv_b,v_arr,v_inc,bl_b,v_ship,
              LEAST(v_inc, GREATEST(0, v_ship - bl_b)),
              inv_b + v_arr - v_ship, bl_b + v_inc - v_ship,
              (inv_b + v_arr - v_ship) * h, (bl_b + v_inc - v_ship) * b);
      IF r <> 'retailer' AND v_ship > 0 THEN
        INSERT INTO lab.pipeline(round_id,team_no,role,arrival_week,qty,source,created_week)
        VALUES (p_round,tm,lab.ships_to(r),t + rd.lead_time,v_ship,'shipment',t);
      END IF;
    END LOOP;
  END LOOP;
END $$;

-- Close week t: auto-fill missing orders, release supplier production, expedites.
CREATE FUNCTION lab.close_week(p_round uuid, t int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE rd lab.rounds; orec record; cap numeric; prod int; n_auto int := 0; ecost numeric;
BEGIN
  SELECT * INTO rd FROM lab.rounds WHERE id = p_round;
  cap := lab.cfg(rd.room_id,'supplier_capacity'); ecost := lab.cfg(rd.room_id,'expedite_cost');
  -- auto-fill: repeat previous order (seed for week 1)
  WITH missing AS (
    SELECT rt.team_no, r.role FROM lab.round_teams rt CROSS JOIN unnest(lab.roles()) AS r(role)
    WHERE rt.round_id = p_round AND NOT EXISTS (SELECT 1 FROM lab.orders o
      WHERE o.round_id=p_round AND o.team_no=rt.team_no AND o.role=r.role AND o.week=t))
  INSERT INTO lab.orders(round_id,team_no,role,week,qty,auto_filled)
  SELECT p_round, m.team_no, m.role, t,
         COALESCE((SELECT qty FROM lab.orders WHERE round_id=p_round AND team_no=m.team_no AND role=m.role AND week=t-1),
                  lab.cfg(rd.room_id,'init_flow')::int), true
  FROM missing m;
  GET DIAGNOSTICS n_auto = ROW_COUNT;
  INSERT INTO lab.order_log(round_id,team_no,role,week,qty,expedite,outcome)
  SELECT round_id,team_no,role,week,qty,0,'auto_filled' FROM lab.orders
  WHERE round_id=p_round AND week=t AND auto_filled AND version=1 AND submitted_by IS NULL;

  FOR orec IN SELECT * FROM lab.orders WHERE round_id=p_round AND week=t LOOP
    IF orec.role = 'supplier' THEN
      prod := CASE WHEN cap IS NULL THEN orec.qty ELSE LEAST(orec.qty, cap::int) END;
      IF prod > 0 THEN
        INSERT INTO lab.pipeline(round_id,team_no,role,arrival_week,qty,source,created_week)
        VALUES (p_round,orec.team_no,'supplier',t + 1 + rd.lead_time,prod,'production',t);
      END IF;
    END IF;
    IF orec.expedite > 0 THEN
      IF rd.mode <> 'SHOCK' THEN RAISE EXCEPTION 'expedite only allowed in SHOCK'; END IF;
      INSERT INTO lab.pipeline(round_id,team_no,role,arrival_week,qty,source,created_week)
      VALUES (p_round,orec.team_no,orec.role,t + 1,orec.expedite,'expedite',t);
      UPDATE lab.stage_week SET expedite_cost = orec.expedite * ecost
       WHERE round_id=p_round AND team_no=orec.team_no AND role=orec.role AND week=t;
    END IF;
  END LOOP;
  RETURN n_auto;
END $$;

-- Create + start a round attempt (used by start_round and reset_round).
CREATE FUNCTION lab.create_round(p_room uuid, p_round_no int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_att int; v_mode text; L int; nw int; init_flow int; tm int; r text; wk int;
        r1 uuid; n_dem int;
BEGIN
  v_mode := (ARRAY['SILO','SHARE','SHOCK'])[p_round_no];
  L := lab.cfg(p_room,'lead_time'); nw := lab.cfg(p_room,'weeks'); init_flow := lab.cfg(p_room,'init_flow');
  SELECT COALESCE(max(attempt),0)+1 INTO v_att FROM lab.rounds WHERE room_id=p_room AND round_no=p_round_no;
  IF p_round_no = 2 THEN   -- Round 2 must replay exactly Round 1's horizon (Round 1 may have ended early)
    SELECT weeks INTO nw FROM lab.rounds WHERE room_id=p_room AND round_no=1 ORDER BY attempt DESC LIMIT 1;
  END IF;
  UPDATE lab.rounds SET active=false WHERE room_id=p_room AND active;          -- one active round per room
  INSERT INTO lab.rounds(room_id,round_no,attempt,mode,status,current_week,weeks,lead_time,shock_week)
  VALUES (p_room,p_round_no,v_att,v_mode,'playing',1,nw,L,
          CASE WHEN p_round_no=3 THEN lab.cfg(p_room,'shock_week')::int END)
  RETURNING id INTO v_id;

  -- DEMAND: Round 1 and Round 2 must be IDENTICAL. Both copy the locked BASE template.
  IF p_round_no IN (1,2) THEN
    INSERT INTO lab.demand SELECT v_id, week, qty FROM lab.demand_template
      WHERE room_id=p_room AND round_kind='BASE' AND week <= nw;
    IF p_round_no = 2 THEN               -- defensive equality check against Round 1's actual demand
      SELECT id INTO r1 FROM lab.rounds WHERE room_id=p_room AND round_no=1 ORDER BY attempt DESC LIMIT 1;
      IF r1 IS NULL THEN RAISE EXCEPTION 'round 1 has not been played'; END IF;
      IF EXISTS ((SELECT week,qty FROM lab.demand WHERE round_id=r1 AND week <= nw EXCEPT SELECT week,qty FROM lab.demand WHERE round_id=v_id)
                 UNION ALL
                 (SELECT week,qty FROM lab.demand WHERE round_id=v_id EXCEPT SELECT week,qty FROM lab.demand WHERE round_id=r1))
      THEN RAISE EXCEPTION 'round 2 demand differs from round 1'; END IF;
    END IF;
  ELSE
    INSERT INTO lab.demand SELECT v_id, week, qty FROM lab.demand_template
      WHERE room_id=p_room AND round_kind='SHOCK' AND week <= nw;
  END IF;
  SELECT count(*) INTO n_dem FROM lab.demand WHERE round_id=v_id;
  IF n_dem <> nw THEN RAISE EXCEPTION 'demand has % weeks, expected %', n_dem, nw; END IF;
  UPDATE lab.rooms SET demand_locked = true WHERE id = p_room;

  -- Teams: every team with at least one seat row. Empty seats are played by AUTO (repeat-last).
  INSERT INTO lab.round_teams SELECT DISTINCT v_id, team_no FROM lab.seats WHERE room_id=p_room;
  IF NOT EXISTS (SELECT 1 FROM lab.round_teams WHERE round_id=v_id) THEN RAISE EXCEPTION 'no teams'; END IF;

  -- Seed steady-state pipeline (init_flow arriving weeks 1..L; supplier 1..L+1).
  FOR tm IN SELECT team_no FROM lab.round_teams WHERE round_id=v_id LOOP
    FOREACH r IN ARRAY lab.roles() LOOP
      FOR wk IN 1 .. (CASE WHEN r='supplier' THEN L+1 ELSE L END) LOOP
        INSERT INTO lab.pipeline(round_id,team_no,role,arrival_week,qty,source,created_week)
        VALUES (v_id,tm,r,wk,init_flow,'seed',0);
      END LOOP;
    END LOOP;
  END LOOP;
  PERFORM lab.open_week(v_id, 1);
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------- VIEW BUILDERS (private)
CREATE FUNCTION lab.stage_snapshot(p_round uuid, tm int, r text, t int) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'role', r,
    'inventory', sw.inv_after, 'received_this_week', sw.arrivals,
    'incoming_order', sw.incoming_order, 'shipped', sw.shipped, 'backorder', sw.backlog_after,
    'on_the_way', COALESCE((SELECT jsonb_agg(jsonb_build_object('arrives_in_weeks', arrival_week - t, 'qty', s)
                             ORDER BY arrival_week)
                    FROM (SELECT arrival_week, sum(qty) s FROM lab.pipeline
                          WHERE round_id=p_round AND team_no=tm AND role=r AND arrival_week > t
                          GROUP BY arrival_week) p), '[]'::jsonb),
    'cost_to_date', (SELECT sum(holding_cost+backlog_cost+expedite_cost) FROM lab.stage_week
                     WHERE round_id=p_round AND team_no=tm AND role=r AND week <= t),
    'history', (SELECT jsonb_agg(jsonb_build_object('week', s2.week, 'inventory', s2.inv_after,
                     'backorder', s2.backlog_after, 'incoming_order', s2.incoming_order,
                     'received', s2.arrivals, 'my_order', o.qty) ORDER BY s2.week)
                FROM lab.stage_week s2 LEFT JOIN lab.orders o ON o.round_id=s2.round_id AND o.team_no=s2.team_no
                     AND o.role=s2.role AND o.week=s2.week
                WHERE s2.round_id=p_round AND s2.team_no=tm AND s2.role=r AND s2.week <= t))
  FROM lab.stage_week sw WHERE sw.round_id=p_round AND sw.team_no=tm AND sw.role=r AND sw.week=t
$$;

-- ---------------------------------------------------------------- PUBLIC API (SECURITY DEFINER)
CREATE FUNCTION public.bg_create_room(p_config jsonb DEFAULT '{}'::jsonb, p_demo boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_cfg jsonb; v_code text; v_room lab.rooms; base int[]; shock int[]; i int;
BEGIN
  v_cfg := jsonb_build_object('weeks',12,'lead_time',1,'start_inv',20,'init_flow',10,'holding_cost',1,
     'backorder_cost',2,'expedite_cost',3,'supplier_capacity',NULL,'shock_week',5,'max_order',999,
     'show_total_weeks',false,'offline_after_seconds',25) || p_config;
  IF (v_cfg->>'lead_time')::int < 1 THEN RAISE EXCEPTION 'lead_time must be >= 1'; END IF;
  LOOP
    v_code := lpad((floor(random()*10000))::int::text, 4, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lab.rooms WHERE code = v_code);
  END LOOP;
  INSERT INTO lab.rooms(code, config, is_demo) VALUES (v_code, v_cfg, p_demo) RETURNING * INTO v_room;
  base  := ARRAY[10,10,10,12,15,20,20,15,12,10,10,10];
  shock := ARRAY[10,10,10,10,14,14,14,14,14,14,14,14];          -- +40% from shock_week
  FOR i IN 1 .. (v_cfg->>'weeks')::int LOOP
    INSERT INTO lab.demand_template VALUES (v_room.id,'BASE',i, COALESCE(base[i],10));
    INSERT INTO lab.demand_template VALUES (v_room.id,'SHOCK',i, COALESCE(shock[i],14));
  END LOOP;
  RETURN jsonb_build_object('room_code', v_code, 'teacher_token', v_room.teacher_token,
                            'projector_token', v_room.projector_token);
END $$;

CREATE FUNCTION public.bg_teacher_set_demand(p_teacher uuid, p_kind text, p_week int, p_qty int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); BEGIN
  IF p_kind = 'BASE' AND (SELECT demand_locked FROM lab.rooms WHERE id=v_room) THEN
    RAISE EXCEPTION 'demand_locked: base demand cannot change after Round 1 starts (Round 2 must equal Round 1)';
  END IF;
  IF p_kind = 'SHOCK' AND EXISTS (SELECT 1 FROM lab.rounds WHERE room_id=v_room AND round_no=3) THEN
    RAISE EXCEPTION 'demand_locked: shock demand cannot change after Round 3 starts';
  END IF;
  IF p_qty IS NULL OR p_qty < 0 THEN RAISE EXCEPTION 'invalid quantity'; END IF;
  UPDATE lab.demand_template SET qty=p_qty WHERE room_id=v_room AND round_kind=p_kind AND week=p_week;
  IF NOT FOUND THEN RAISE EXCEPTION 'no such week'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- Shock presets (teacher picks before Round 3; actual outcome stays hidden from students).
--   MILD  : +40% sustained from shock_week (spec example) — buffers absorb it; "do nothing" tends to win.
--   SPIKE : front-loaded surge then settles at +40% — punishes inaction, rewards measured hedging.
--   NONE  : the rumour was false — punishes over-reaction.
CREATE FUNCTION public.bg_teacher_set_shock_preset(p_teacher uuid, p_preset text) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); sw int; w int; nw int; q int; BEGIN
  sw := lab.cfg(v_room,'shock_week'); nw := lab.cfg(v_room,'weeks');
  FOR w IN 1 .. nw LOOP
    q := CASE WHEN w < sw THEN 10
              WHEN p_preset = 'MILD'  THEN 14
              WHEN p_preset = 'SPIKE' THEN (ARRAY[20,20,18,16])[w - sw + 1]
              WHEN p_preset = 'NONE'  THEN 10 END;
    IF p_preset NOT IN ('MILD','SPIKE','NONE') THEN RAISE EXCEPTION 'unknown_preset'; END IF;
    PERFORM public.bg_teacher_set_demand(p_teacher, 'SHOCK', w, COALESCE(q, 14));
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'preset', p_preset);
END $$;

CREATE FUNCTION public.bg_join_room(p_code text, p_name text, p_student_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room lab.rooms; v_player lab.players; v_team int; v_role text; started boolean;
BEGIN
  SELECT * INTO v_room FROM lab.rooms WHERE code = p_code FOR UPDATE;   -- serialize seat assignment
  IF v_room.id IS NULL THEN RAISE EXCEPTION 'room_not_found'; END IF;
  IF COALESCE(trim(p_name),'') = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  INSERT INTO lab.players(room_id,name,student_code) VALUES (v_room.id, left(trim(p_name),60), p_student_code)
  RETURNING * INTO v_player;
  started := EXISTS (SELECT 1 FROM lab.rounds WHERE room_id=v_room.id);
  IF NOT started THEN
    -- fill first empty seat; otherwise open a new team
    SELECT team_no, role INTO v_team, v_role FROM lab.seats
      WHERE room_id=v_room.id AND player_id IS NULL
      ORDER BY team_no, array_position(lab.roles(), role) LIMIT 1;
    IF v_team IS NULL THEN
      SELECT COALESCE(max(team_no),0)+1 INTO v_team FROM lab.seats WHERE room_id=v_room.id;
      INSERT INTO lab.seats(room_id,team_no,role) SELECT v_room.id, v_team, unnest(lab.roles());
      v_role := 'retailer';
    END IF;
    UPDATE lab.seats SET player_id=v_player.id WHERE room_id=v_room.id AND team_no=v_team AND role=v_role;
  END IF;  -- late joiners wait in the lobby until the teacher assigns them
  RETURN jsonb_build_object('player_token', v_player.token, 'team', v_team, 'role', v_role,
                            'waiting', v_team IS NULL);
END $$;

CREATE FUNCTION lab.player_by_token(p_token uuid) RETURNS lab.players LANGUAGE plpgsql AS $$
DECLARE p lab.players; BEGIN
  UPDATE lab.players SET last_seen = now() WHERE token = p_token RETURNING * INTO p;   -- doubles as heartbeat
  IF p.id IS NULL THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  RETURN p; END $$;

CREATE FUNCTION public.bg_heartbeat(p_token uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = lab, public, pg_temp AS $$ BEGIN PERFORM lab.player_by_token(p_token);
  RETURN '{"ok":true}'; END $$;

-- STUDENT VIEW: the only way a student reads game state. Restricted by construction.
CREATE FUNCTION public.bg_student_view(p_token uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = lab, public, pg_temp AS $$
DECLARE p lab.players; s lab.seats; rd lab.rounds; v jsonb; my_order lab.orders; shared boolean;
BEGIN
  p := lab.player_by_token(p_token);
  SELECT * INTO s FROM lab.seats WHERE player_id = p.id;
  rd := lab.active_round(p.room_id);
  v := jsonb_build_object('name', p.name, 'room_code', (SELECT code FROM lab.rooms WHERE id=p.room_id),
                          'team', s.team_no, 'role', s.role, 'waiting', s.team_no IS NULL);
  IF rd.id IS NULL OR s.team_no IS NULL THEN RETURN v || jsonb_build_object('status','lobby'); END IF;
  IF NOT EXISTS (SELECT 1 FROM lab.round_teams WHERE round_id=rd.id AND team_no=s.team_no) THEN
    RETURN v || jsonb_build_object('status','not_in_round');
  END IF;
  SELECT * INTO my_order FROM lab.orders WHERE round_id=rd.id AND team_no=s.team_no AND role=s.role AND week=rd.current_week;
  v := v || jsonb_build_object(
    'round', rd.round_no, 'mode', rd.mode, 'status', rd.status, 'week', rd.current_week,
    'total_weeks', CASE WHEN (SELECT (config->>'show_total_weeks')::boolean FROM lab.rooms WHERE id=p.room_id)
                        THEN rd.weeks END,
    'me', lab.stage_snapshot(rd.id, s.team_no, s.role, rd.current_week),
    'submitted', my_order.qty IS NOT NULL,
    'my_order', my_order.qty, 'auto_filled', COALESCE(my_order.auto_filled,false),
    'can_edit', COALESCE(my_order.edit_allowed,false),
    'order_to', CASE s.role WHEN 'retailer' THEN 'distributor' WHEN 'distributor' THEN 'manufacturer'
                            WHEN 'manufacturer' THEN 'supplier' ELSE 'production' END);
  shared := rd.mode IN ('SHARE','SHOCK');
  IF shared THEN
    -- customer demand: CURRENT and PAST weeks only, never future
    v := v || jsonb_build_object(
      'customer_demand', (SELECT jsonb_agg(jsonb_build_object('week',week,'qty',qty) ORDER BY week)
                          FROM lab.demand WHERE round_id=rd.id AND week <= rd.current_week),
      'team_status', (SELECT jsonb_agg(lab.stage_snapshot(rd.id, s.team_no, r, rd.current_week) - 'history'
                                       ORDER BY array_position(lab.roles(), r))
                      FROM unnest(lab.roles()) r),
      'team_notes', (SELECT body FROM lab.team_notes WHERE round_id=rd.id AND team_no=s.team_no));
  END IF;
  IF rd.mode = 'SHOCK' AND rd.shock_announced THEN
    v := v || jsonb_build_object('alert', jsonb_build_object('th',
      'ด่วน! อินฟลูเอนเซอร์ TikTok รีวิวสินค้าของเรา ฝ่ายการตลาดคาดว่าความต้องการ "อาจ" เพิ่มขึ้นได้ถึง 200% ในสัปดาห์หน้า',
      'en', 'A major TikTok influencer reviewed your product. Marketing believes demand MAY increase by up to 200% next week.'),
      'strategy', (SELECT to_jsonb(x) - 'round_id' FROM lab.strategy_decisions x WHERE round_id=rd.id AND team_no=s.team_no),
      'planning', (SELECT to_jsonb(x) - 'round_id' FROM lab.planning_decisions x WHERE round_id=rd.id AND team_no=s.team_no));
  END IF;
  RETURN v;
END $$;

CREATE FUNCTION public.bg_submit_order(p_token uuid, p_week int, p_qty int, p_expedite int DEFAULT 0,
   p_production_qty int DEFAULT NULL, p_priority text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE p lab.players; s lab.seats; rd lab.rounds; ex lab.orders; maxo int;
BEGIN
  p := lab.player_by_token(p_token);
  SELECT * INTO s FROM lab.seats WHERE player_id = p.id;
  IF s.team_no IS NULL THEN RAISE EXCEPTION 'no_seat'; END IF;
  SELECT * INTO rd FROM lab.rounds WHERE room_id=p.room_id AND active FOR SHARE;   -- blocks while a week is processing
  IF rd.id IS NULL OR rd.status <> 'playing' THEN RAISE EXCEPTION 'round_not_accepting_orders'; END IF;
  IF p_week IS DISTINCT FROM rd.current_week THEN
    INSERT INTO lab.order_log(round_id,team_no,role,week,qty,expedite,player_id,outcome)
    VALUES (rd.id,s.team_no,s.role,p_week,p_qty,p_expedite,p.id,'stale_week');
    RETURN jsonb_build_object('ok', false, 'error', 'stale_week', 'current_week', rd.current_week);
  END IF;
  maxo := lab.cfg(p.room_id,'max_order');
  IF p_qty IS NULL OR p_qty < 0 OR p_qty > maxo THEN RAISE EXCEPTION 'invalid_quantity'; END IF;
  IF COALESCE(p_expedite,0) < 0 OR (COALESCE(p_expedite,0) > 0 AND rd.mode <> 'SHOCK') THEN
    RAISE EXCEPTION 'expedite_not_allowed'; END IF;

  INSERT INTO lab.orders(round_id,team_no,role,week,qty,expedite,production_qty,shipment_priority,submitted_by)
  VALUES (rd.id,s.team_no,s.role,rd.current_week,p_qty,COALESCE(p_expedite,0),p_production_qty,p_priority,p.id)
  ON CONFLICT DO NOTHING;
  IF FOUND THEN
    INSERT INTO lab.order_log(round_id,team_no,role,week,qty,expedite,player_id,outcome)
    VALUES (rd.id,s.team_no,s.role,rd.current_week,p_qty,p_expedite,p.id,'accepted');
    RETURN jsonb_build_object('ok', true, 'qty', p_qty, 'week', rd.current_week);
  END IF;
  SELECT * INTO ex FROM lab.orders WHERE round_id=rd.id AND team_no=s.team_no AND role=s.role AND week=rd.current_week FOR UPDATE;
  IF ex.edit_allowed THEN
    UPDATE lab.orders SET qty=p_qty, expedite=COALESCE(p_expedite,0), production_qty=p_production_qty,
      shipment_priority=p_priority, submitted_by=p.id, edit_allowed=false, auto_filled=false,
      version=version+1, submitted_at=clock_timestamp()
    WHERE round_id=rd.id AND team_no=s.team_no AND role=s.role AND week=rd.current_week;
    INSERT INTO lab.order_log(round_id,team_no,role,week,qty,expedite,player_id,outcome)
    VALUES (rd.id,s.team_no,s.role,rd.current_week,p_qty,p_expedite,p.id,'edited');
    RETURN jsonb_build_object('ok', true, 'qty', p_qty, 'week', rd.current_week, 'edited', true);
  END IF;
  INSERT INTO lab.order_log(round_id,team_no,role,week,qty,expedite,player_id,outcome)
  VALUES (rd.id,s.team_no,s.role,rd.current_week,p_qty,p_expedite,p.id,'duplicate_rejected');
  RETURN jsonb_build_object('ok', false, 'error', 'already_submitted', 'qty', ex.qty);
END $$;

CREATE FUNCTION public.bg_save_team_notes(p_token uuid, p_body text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = lab, public, pg_temp AS $$
DECLARE p lab.players; s lab.seats; rd lab.rounds; BEGIN
  p := lab.player_by_token(p_token); SELECT * INTO s FROM lab.seats WHERE player_id=p.id;
  rd := lab.active_round(p.room_id);
  IF rd.mode = 'SILO' OR rd.id IS NULL THEN RAISE EXCEPTION 'notes_disabled_in_silo'; END IF;
  INSERT INTO lab.team_notes VALUES (rd.id, s.team_no, left(p_body,4000), p.id, now())
  ON CONFLICT (round_id,team_no) DO UPDATE SET body=excluded.body, updated_by=excluded.updated_by, updated_at=now();
  RETURN '{"ok":true}'; END $$;

CREATE FUNCTION public.bg_submit_strategy(p_token uuid, p_priority text, p_risks text[], p_rationale text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE p lab.players; s lab.seats; rd lab.rounds; BEGIN
  p := lab.player_by_token(p_token); SELECT * INTO s FROM lab.seats WHERE player_id=p.id;
  rd := lab.active_round(p.room_id);
  IF rd.mode <> 'SHOCK' OR NOT rd.shock_announced THEN RAISE EXCEPTION 'strategy_not_open'; END IF;
  IF NOT p_risks <@ ARRAY['STOCKOUT','INVENTORY','EXPEDITE_COST','CAPACITY'] THEN RAISE EXCEPTION 'invalid_risk'; END IF;
  INSERT INTO lab.strategy_decisions VALUES (rd.id,s.team_no,p_priority,p_risks,p_rationale,p.id,now())
  ON CONFLICT (round_id,team_no) DO UPDATE SET priority=excluded.priority, accepted_risks=excluded.accepted_risks,
     rationale=excluded.rationale, submitted_by=excluded.submitted_by, submitted_at=now();
  RETURN '{"ok":true}'; END $$;

CREATE FUNCTION public.bg_submit_planning(p_token uuid, p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = lab, public, pg_temp AS $$
DECLARE pl lab.players; s lab.seats; rd lab.rounds; BEGIN
  pl := lab.player_by_token(p_token); SELECT * INTO s FROM lab.seats WHERE player_id=pl.id;
  rd := lab.active_round(pl.room_id);
  IF rd.mode <> 'SHOCK' OR NOT rd.shock_announced THEN RAISE EXCEPTION 'planning_not_open'; END IF;
  INSERT INTO lab.planning_decisions VALUES (rd.id,s.team_no,p->>'safety_stock',p->>'temporary_capacity',
     p->>'supplier_preparation',p->>'transportation_capacity',p->>'demand_monitoring',p->>'contingency_plan',pl.id,now())
  ON CONFLICT (round_id,team_no) DO UPDATE SET safety_stock=excluded.safety_stock,
     temporary_capacity=excluded.temporary_capacity, supplier_preparation=excluded.supplier_preparation,
     transportation_capacity=excluded.transportation_capacity, demand_monitoring=excluded.demand_monitoring,
     contingency_plan=excluded.contingency_plan, submitted_by=excluded.submitted_by, submitted_at=now();
  RETURN '{"ok":true}'; END $$;

-- ---------------------------------------------------------------- TEACHER API
CREATE FUNCTION public.bg_teacher_start_round(p_teacher uuid, p_round_no int) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); cur lab.rounds; v uuid; BEGIN
  PERFORM 1 FROM lab.rooms WHERE id=v_room FOR UPDATE;                 -- serialize double-clicks
  cur := lab.active_round(v_room);
  IF cur.id IS NOT NULL AND cur.round_no = p_round_no THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_started');
  END IF;
  IF cur.id IS NOT NULL AND cur.status NOT IN ('complete','revealed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'current_round_not_finished');
  END IF;
  IF p_round_no > 1 AND (cur.id IS NULL OR cur.round_no <> p_round_no - 1) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rounds_must_run_in_order');
  END IF;
  v := lab.create_round(v_room, p_round_no);
  INSERT INTO lab.teacher_actions(room_id,action,detail,outcome) VALUES (v_room,'start_round',jsonb_build_object('round',p_round_no),'ok');
  RETURN jsonb_build_object('ok', true, 'round_id', v);
END $$;

CREATE FUNCTION public.bg_teacher_advance_week(p_teacher uuid, p_expected_week int, p_force boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); rd lab.rounds; n_missing int; n_auto int; BEGIN
  SELECT * INTO rd FROM lab.rounds WHERE room_id=v_room AND active FOR UPDATE;   -- exclusive: serializes double-clicks
  IF rd.id IS NULL THEN RETURN jsonb_build_object('ok',false,'error','no_active_round'); END IF;
  IF rd.status <> 'playing' OR rd.current_week <> p_expected_week THEN
    INSERT INTO lab.teacher_actions(room_id,action,detail,outcome)
    VALUES (v_room,'advance',jsonb_build_object('expected',p_expected_week,'actual',rd.current_week,'status',rd.status),'ignored_stale');
    RETURN jsonb_build_object('ok',false,'error','stale_or_not_playing','week',rd.current_week,'status',rd.status);
  END IF;
  SELECT count(*) INTO n_missing FROM lab.round_teams rt CROSS JOIN unnest(lab.roles()) r(role)
   WHERE rt.round_id=rd.id AND NOT EXISTS (SELECT 1 FROM lab.orders o WHERE o.round_id=rd.id
         AND o.team_no=rt.team_no AND o.role=r.role AND o.week=rd.current_week);
  IF n_missing > 0 AND NOT p_force THEN
    RETURN jsonb_build_object('ok',false,'error','missing_submissions','missing',n_missing,
      'message_th', n_missing || ' คนยังไม่ส่งคำสั่งซื้อ ต้องการไปต่อหรือไม่? (ระบบจะใช้คำสั่งซื้อเดิมของสัปดาห์ก่อน)',
      'message_en', n_missing || ' students have not submitted. Continue anyway? (Their previous order will be repeated.)');
  END IF;
  n_auto := lab.close_week(rd.id, rd.current_week);
  IF rd.current_week < rd.weeks THEN
    PERFORM lab.open_week(rd.id, rd.current_week + 1);
    UPDATE lab.rounds SET current_week = current_week + 1 WHERE id = rd.id;
  ELSE
    UPDATE lab.rounds SET status = 'complete' WHERE id = rd.id;
  END IF;
  INSERT INTO lab.teacher_actions(room_id,action,detail,outcome)
  VALUES (v_room,'advance',jsonb_build_object('from_week',rd.current_week,'auto_filled',n_auto),'ok');
  RETURN jsonb_build_object('ok',true,'auto_filled',n_auto,
     'week', CASE WHEN rd.current_week < rd.weeks THEN rd.current_week+1 ELSE rd.current_week END,
     'status', CASE WHEN rd.current_week < rd.weeks THEN 'playing' ELSE 'complete' END);
END $$;

CREATE FUNCTION public.bg_teacher_set_status(p_teacher uuid, p_action text) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); rd lab.rounds; BEGIN
  SELECT * INTO rd FROM lab.rounds WHERE room_id=v_room AND active FOR UPDATE;
  IF rd.id IS NULL THEN RAISE EXCEPTION 'no_active_round'; END IF;
  CASE p_action
    WHEN 'pause'  THEN IF rd.status='playing' THEN UPDATE lab.rounds SET status='paused' WHERE id=rd.id; END IF;
    WHEN 'resume' THEN IF rd.status='paused'  THEN UPDATE lab.rounds SET status='playing' WHERE id=rd.id; END IF;
    WHEN 'end_round' THEN   -- early end: close the current week (auto-fill missing orders) so every series has equal length
      IF rd.status IN ('playing','paused') THEN
        PERFORM lab.close_week(rd.id, rd.current_week);
        UPDATE lab.rounds SET status='complete', weeks=rd.current_week WHERE id=rd.id;
      END IF;
    WHEN 'reveal' THEN
      IF rd.status = 'complete' THEN UPDATE lab.rounds SET status='revealed', report = lab.round_report(rd.id) WHERE id=rd.id;
      ELSIF rd.status <> 'revealed' THEN RAISE EXCEPTION 'cannot_reveal_while_playing'; END IF;
    WHEN 'announce_shock' THEN
      IF rd.mode <> 'SHOCK' THEN RAISE EXCEPTION 'not_shock_round'; END IF;
      UPDATE lab.rounds SET shock_announced=true WHERE id=rd.id;
    ELSE RAISE EXCEPTION 'unknown_action';
  END CASE;
  INSERT INTO lab.teacher_actions(room_id,action,outcome) VALUES (v_room,p_action,'ok');
  RETURN jsonb_build_object('ok',true,'status',(SELECT status FROM lab.rounds WHERE id=rd.id));
END $$;

CREATE FUNCTION public.bg_teacher_allow_edit(p_teacher uuid, p_team int, p_role text) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); rd lab.rounds; BEGIN
  SELECT * INTO rd FROM lab.rounds WHERE room_id=v_room AND active FOR UPDATE;
  UPDATE lab.orders SET edit_allowed=true WHERE round_id=rd.id AND team_no=p_team AND role=p_role AND week=rd.current_week;
  RETURN jsonb_build_object('ok', FOUND);
END $$;

CREATE FUNCTION public.bg_teacher_reset_round(p_teacher uuid) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); cur lab.rounds; v uuid; BEGIN
  PERFORM 1 FROM lab.rooms WHERE id=v_room FOR UPDATE;
  cur := lab.active_round(v_room);
  IF cur.id IS NULL THEN RAISE EXCEPTION 'no_active_round'; END IF;
  PERFORM 1 FROM lab.rounds WHERE id=cur.id FOR UPDATE;
  -- New attempt: fresh inventory/backlog/pipeline/orders/notes/decisions. Old attempt kept, inactive, for audit.
  v := lab.create_round(v_room, cur.round_no);
  INSERT INTO lab.teacher_actions(room_id,action,detail,outcome) VALUES (v_room,'reset_round',
     jsonb_build_object('round',cur.round_no,'old',cur.id,'new',v),'ok');
  RETURN jsonb_build_object('ok',true,'round_id',v);
END $$;

-- Seat management: move/swap before start; replace / take over at any time.
CREATE FUNCTION public.bg_teacher_assign_seat(p_teacher uuid, p_player uuid, p_team int, p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); occupant uuid; old lab.seats; BEGIN
  PERFORM 1 FROM lab.rooms WHERE id=v_room FOR UPDATE;
  IF p_player IS NOT NULL AND NOT EXISTS (SELECT 1 FROM lab.players WHERE id=p_player AND room_id=v_room) THEN
    RAISE EXCEPTION 'player_not_in_room'; END IF;
  INSERT INTO lab.seats(room_id,team_no,role) VALUES (v_room,p_team,p_role) ON CONFLICT DO NOTHING;
  INSERT INTO lab.seats(room_id,team_no,role) SELECT v_room,p_team,r FROM unnest(lab.roles()) r ON CONFLICT DO NOTHING;
  SELECT player_id INTO occupant FROM lab.seats WHERE room_id=v_room AND team_no=p_team AND role=p_role;
  SELECT * INTO old FROM lab.seats WHERE player_id = p_player;
  UPDATE lab.seats SET player_id = NULL WHERE player_id = p_player;
  UPDATE lab.seats SET player_id = p_player WHERE room_id=v_room AND team_no=p_team AND role=p_role;
  IF occupant IS NOT NULL AND old.team_no IS NOT NULL AND occupant IS DISTINCT FROM p_player THEN  -- swap
    UPDATE lab.seats SET player_id = occupant WHERE room_id=v_room AND team_no=old.team_no AND role=old.role;
  END IF;
  INSERT INTO lab.teacher_actions(room_id,action,detail,outcome) VALUES (v_room,'assign_seat',
    jsonb_build_object('player',p_player,'team',p_team,'role',p_role,'displaced',occupant),'ok');
  RETURN '{"ok":true}';
END $$;

CREATE FUNCTION public.bg_teacher_take_over(p_teacher uuid, p_team int, p_role text) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); pl lab.players; BEGIN
  INSERT INTO lab.players(room_id,name,is_teacher) VALUES (v_room,'Teacher (T'||p_team||' '||p_role||')',true) RETURNING * INTO pl;
  PERFORM public.bg_teacher_assign_seat(p_teacher, NULL, p_team, p_role);   -- frees seat
  UPDATE lab.seats SET player_id = pl.id WHERE room_id=v_room AND team_no=p_team AND role=p_role;
  RETURN jsonb_build_object('ok',true,'player_token',pl.token);
END $$;

CREATE FUNCTION public.bg_teacher_issue_rejoin_pin(p_teacher uuid, p_team int, p_role text) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); pid uuid; pin text; BEGIN
  SELECT player_id INTO pid FROM lab.seats WHERE room_id=v_room AND team_no=p_team AND role=p_role;
  IF pid IS NULL THEN RAISE EXCEPTION 'seat_empty'; END IF;
  pin := lpad((floor(random()*1000000))::int::text,6,'0');
  UPDATE lab.players SET rejoin_pin = pin WHERE id = pid;
  RETURN jsonb_build_object('ok',true,'pin',pin);
END $$;

-- Student lost their device/token: room code + teacher-issued PIN → new token for the SAME seat.
CREATE FUNCTION public.bg_rejoin_with_pin(p_code text, p_pin text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = lab, public, pg_temp AS $$
DECLARE pl lab.players; BEGIN
  UPDATE lab.players SET token = gen_random_uuid(), rejoin_pin = NULL, last_seen = now()
  WHERE room_id = (SELECT id FROM lab.rooms WHERE code=p_code) AND rejoin_pin = p_pin AND p_pin IS NOT NULL
  RETURNING * INTO pl;
  IF pl.id IS NULL THEN RAISE EXCEPTION 'invalid_pin'; END IF;
  RETURN jsonb_build_object('player_token', pl.token);   -- old token is now invalid
END $$;

CREATE FUNCTION public.bg_teacher_view(p_teacher uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); rd lab.rounds; off int; BEGIN
  rd := lab.active_round(v_room);
  off := lab.cfg(v_room,'offline_after_seconds');
  RETURN jsonb_build_object(
    'room_code', (SELECT code FROM lab.rooms WHERE id=v_room),
    'round', rd.round_no, 'mode', rd.mode, 'status', rd.status, 'week', rd.current_week, 'weeks', rd.weeks,
    'shock_announced', rd.shock_announced,
    'demand_schedule', (SELECT jsonb_agg(jsonb_build_object('week',week,'qty',qty) ORDER BY week) FROM lab.demand WHERE round_id=rd.id),
    'templates', jsonb_build_object(
        'BASE', (SELECT jsonb_agg(qty ORDER BY week) FROM lab.demand_template WHERE room_id=v_room AND round_kind='BASE'),
        'SHOCK', (SELECT jsonb_agg(qty ORDER BY week) FROM lab.demand_template WHERE room_id=v_room AND round_kind='SHOCK')),
    'demand_locked', (SELECT demand_locked FROM lab.rooms WHERE id=v_room),
    'decisions', COALESCE((SELECT jsonb_agg(jsonb_build_object('team', rt.team_no,
         'strategy', (SELECT to_jsonb(x) - 'round_id' FROM lab.strategy_decisions x WHERE x.round_id=rd.id AND x.team_no=rt.team_no),
         'planning', (SELECT to_jsonb(x) - 'round_id' FROM lab.planning_decisions x WHERE x.round_id=rd.id AND x.team_no=rt.team_no),
         'notes', (SELECT body FROM lab.team_notes x WHERE x.round_id=rd.id AND x.team_no=rt.team_no)) ORDER BY rt.team_no)
       FROM lab.round_teams rt WHERE rt.round_id=rd.id), '[]'::jsonb),
    'connected', (SELECT count(*) FROM lab.players WHERE room_id=v_room AND NOT is_teacher AND last_seen > now() - make_interval(secs=>off)),
    'lobby', COALESCE((SELECT jsonb_agg(jsonb_build_object('player_id',p.id,'name',p.name) ORDER BY p.joined_at) FROM lab.players p
              WHERE p.room_id=v_room AND NOT p.is_teacher AND NOT EXISTS (SELECT 1 FROM lab.seats s WHERE s.player_id=p.id)), '[]'::jsonb),
    'seats', COALESCE((SELECT jsonb_agg(jsonb_build_object('team',s.team_no,'role',s.role,'player_id',p.id,'name',p.name,
               'online', p.last_seen > now() - make_interval(secs=>off), 'teacher_controlled', COALESCE(p.is_teacher,false),
               'submitted', o.qty IS NOT NULL, 'order', o.qty, 'auto', o.auto_filled,
               'inventory', sw.inv_after, 'backorder', sw.backlog_after, 'incoming_order', sw.incoming_order)
               ORDER BY s.team_no, array_position(lab.roles(), s.role))
              FROM lab.seats s LEFT JOIN lab.players p ON p.id=s.player_id
              LEFT JOIN lab.orders o ON o.round_id=rd.id AND o.team_no=s.team_no AND o.role=s.role AND o.week=rd.current_week
              LEFT JOIN lab.stage_week sw ON sw.round_id=rd.id AND sw.team_no=s.team_no AND sw.role=s.role AND sw.week=rd.current_week
              WHERE s.room_id=v_room), '[]'::jsonb));
END $$;

-- PROJECTOR VIEW: separate token. During play it NEVER includes demand, orders, or stage states.
CREATE FUNCTION public.bg_projector_view(p_projector uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid; rd lab.rounds; v jsonb; BEGIN
  SELECT id INTO v_room FROM lab.rooms WHERE projector_token = p_projector;
  IF v_room IS NULL THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  rd := lab.active_round(v_room);
  v := jsonb_build_object('room_code',(SELECT code FROM lab.rooms WHERE id=v_room),
        'round', rd.round_no, 'mode', rd.mode, 'status', rd.status, 'week', rd.current_week,
        'teams', (SELECT jsonb_agg(jsonb_build_object('team', rt.team_no, 'submitted',
                    (SELECT count(*) FROM lab.orders o WHERE o.round_id=rd.id AND o.team_no=rt.team_no AND o.week=rd.current_week),
                    'of', 4) ORDER BY rt.team_no) FROM lab.round_teams rt WHERE rt.round_id=rd.id));
  IF rd.mode='SHOCK' AND rd.shock_announced THEN
    v := v || jsonb_build_object('alert','Demand MAY increase by up to 200% next week.');
  END IF;
  IF rd.status = 'revealed' THEN
    v := v || jsonb_build_object('report', COALESCE(rd.report, lab.round_report(rd.id)),
      'history', COALESCE((SELECT jsonb_agg(COALESCE(x.report, lab.round_report(x.id)) ORDER BY x.round_no) FROM (
          SELECT DISTINCT ON (round_no) id, round_no, report FROM lab.rounds
          WHERE room_id=v_room AND round_no < rd.round_no ORDER BY round_no, attempt DESC) x), '[]'::jsonb));
  END IF;
  RETURN v;
END $$;

-- ---------------------------------------------------------------- REPORTING (single source for graphs)
CREATE FUNCTION lab.round_report(p_round uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
WITH rd AS (SELECT * FROM lab.rounds WHERE id = p_round),
dem AS (SELECT week, qty FROM lab.demand WHERE round_id=p_round AND week <= (SELECT weeks FROM rd)),
dv AS (SELECT var_samp(qty) v, count(*) n FROM dem),
ord AS (SELECT team_no, role, week, qty FROM lab.orders WHERE round_id=p_round AND week <= (SELECT weeks FROM rd)),
sw AS (SELECT * FROM lab.stage_week WHERE round_id=p_round AND week <= (SELECT weeks FROM rd)),
stage AS (
  SELECT s.team_no, s.role,
         sum(s.holding_cost) holding, sum(s.backlog_cost) backlog, sum(s.expedite_cost) expedite,
         sum(s.on_time)::numeric / NULLIF(sum(s.incoming_order),0) fill_rate,
         (SELECT var_samp(qty) FROM ord o WHERE o.team_no=s.team_no AND o.role=s.role) order_var,
         (SELECT count(*) FROM ord o WHERE o.team_no=s.team_no AND o.role=s.role) n_orders
  FROM sw s GROUP BY s.team_no, s.role),
team AS (
  SELECT team_no, sum(holding) holding, sum(backlog) backlog, sum(expedite) expedite,
         sum(holding+backlog+expedite) total_cost,
         (SELECT sum(on_time)::numeric / NULLIF(sum(incoming_order),0) FROM sw WHERE sw.team_no=stage.team_no AND role='retailer') service_level,
         (SELECT avg(inv_after) FROM sw WHERE sw.team_no=stage.team_no) avg_inventory,
         (SELECT max(backlog_after) FROM sw WHERE sw.team_no=stage.team_no) max_backlog,
         (SELECT order_var / NULLIF((SELECT v FROM dv),0) FROM stage s2 WHERE s2.team_no=stage.team_no AND s2.role='supplier') supplier_bullwhip
  FROM stage GROUP BY team_no)
SELECT jsonb_build_object(
  'round_no', (SELECT round_no FROM rd), 'mode', (SELECT mode FROM rd), 'weeks', (SELECT weeks FROM rd),
  'demand', (SELECT jsonb_agg(qty ORDER BY week) FROM dem),
  'demand_variance', (SELECT v FROM dv),
  'bullwhip_note', CASE WHEN (SELECT n FROM dv) < 3 THEN 'insufficient_data'
                        WHEN (SELECT v FROM dv) = 0 THEN 'demand_variance_zero: ratio undefined, compare order std-dev instead'
                        ELSE 'ok' END,
  'teams', (SELECT jsonb_agg(jsonb_build_object(
      'team', t.team_no, 'total_cost', t.total_cost, 'holding_cost', t.holding, 'backorder_cost', t.backlog,
      'expedite_cost', t.expedite, 'service_level', t.service_level, 'avg_inventory', t.avg_inventory,
      'max_backorder', t.max_backlog, 'supplier_bullwhip', t.supplier_bullwhip,
      'avg_chain_inventory', t.avg_inventory * 4,
      'orders', (SELECT jsonb_object_agg(r, (SELECT jsonb_agg(qty ORDER BY week) FROM ord o WHERE o.team_no=t.team_no AND o.role=r))
                 FROM unnest(lab.roles()) r),
      'stages', (SELECT jsonb_object_agg(s.role, jsonb_build_object(
                    'holding_cost', s.holding, 'backorder_cost', s.backlog, 'expedite_cost', s.expedite,
                    'total_cost', s.holding+s.backlog+s.expedite, 'fill_rate', s.fill_rate,
                    'order_variance', s.order_var,
                    'bullwhip', CASE WHEN s.n_orders >= 3 AND (SELECT n FROM dv) >= 3 AND (SELECT v FROM dv) > 0
                                     THEN s.order_var / (SELECT v FROM dv) END))
                 FROM stage s WHERE s.team_no=t.team_no))
      ORDER BY t.team_no) FROM team t))
$$;

CREATE FUNCTION public.bg_round_report(p_teacher uuid, p_round_no int DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE v_room uuid := lab.teacher_room(p_teacher); rid uuid; BEGIN
  IF p_round_no IS NULL THEN rid := (lab.active_round(v_room)).id;
  ELSE SELECT id INTO rid FROM lab.rounds WHERE room_id=v_room AND round_no=p_round_no
       ORDER BY active DESC, attempt DESC LIMIT 1; END IF;
  IF rid IS NULL THEN RAISE EXCEPTION 'no_such_round'; END IF;
  RETURN (SELECT CASE WHEN status = 'revealed' AND report IS NOT NULL THEN report ELSE lab.round_report(id) END
          FROM lab.rounds WHERE id = rid);
END $$;

-- Leaderboard: balanced, min-max normalized across teams (cost↓, service↑, max backorder↓, bullwhip↓).
CREATE FUNCTION public.bg_leaderboard(p_teacher uuid, p_round_no int) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = lab, public, pg_temp AS $$
DECLARE rep jsonb; BEGIN
  rep := public.bg_round_report(p_teacher, p_round_no);
  RETURN (WITH t AS (
      SELECT (x->>'team')::int team, (x->>'total_cost')::numeric cost, (x->>'service_level')::numeric sl,
             (x->>'max_backorder')::numeric mb, (x->>'supplier_bullwhip')::numeric bw
      FROM jsonb_array_elements(rep->'teams') x),
    n AS (SELECT team, cost, sl, mb, bw,
      COALESCE((max(cost) OVER () - cost) / NULLIF(max(cost) OVER () - min(cost) OVER (),0), 1) s_cost,
      COALESCE((sl - min(sl) OVER ()) / NULLIF(max(sl) OVER () - min(sl) OVER (),0), 1) s_sl,
      COALESCE((max(mb) OVER () - mb) / NULLIF(max(mb) OVER () - min(mb) OVER (),0), 1) s_mb,
      COALESCE((max(bw) OVER () - bw) / NULLIF(max(bw) OVER () - min(bw) OVER (),0), 1) s_bw FROM t)
    SELECT jsonb_build_object(
      'ranking', (SELECT jsonb_agg(jsonb_build_object('team',team,'score',round(100*(0.35*s_cost+0.35*s_sl+0.15*s_mb+0.15*s_bw),1))
                  ORDER BY (0.35*s_cost+0.35*s_sl+0.15*s_mb+0.15*s_bw) DESC, team) FROM n),
      'best_overall', (SELECT team FROM n ORDER BY (0.35*s_cost+0.35*s_sl+0.15*s_mb+0.15*s_bw) DESC, team LIMIT 1),
      'best_service', (SELECT team FROM n ORDER BY sl DESC NULLS LAST, team LIMIT 1),
      'lowest_bullwhip', (SELECT team FROM n ORDER BY bw ASC NULLS LAST, team LIMIT 1),
      'lowest_cost', (SELECT team FROM n ORDER BY cost ASC, team LIMIT 1)));
END $$;

-- Student-facing report: only AFTER reveal.
CREATE FUNCTION public.bg_student_report(p_token uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = lab, public, pg_temp AS $$
DECLARE p lab.players; rd lab.rounds; BEGIN
  p := lab.player_by_token(p_token); rd := lab.active_round(p.room_id);
  IF rd.status <> 'revealed' THEN RAISE EXCEPTION 'not_revealed'; END IF;
  RETURN COALESCE(rd.report, lab.round_report(rd.id));
END $$;

-- Audit view (spec §30) for CSV export.
CREATE VIEW lab.v_decision_audit AS
SELECT r.room_id, sw.round_id, r.round_no, r.attempt, sw.team_no, sw.role, p.name AS student, sw.week,
       sw.incoming_order, sw.inv_before, sw.arrivals AS incoming_shipment, sw.backlog_before,
       o.qty AS order_placed, o.auto_filled, sw.inv_after, sw.backlog_after, o.submitted_at AS timestamp
FROM lab.stage_week sw JOIN lab.rounds r ON r.id=sw.round_id
LEFT JOIN lab.orders o USING (round_id, team_no, role, week)
LEFT JOIN lab.players p ON p.id = o.submitted_by;

CREATE FUNCTION public.bg_export_audit(p_teacher uuid) RETURNS jsonb LANGUAGE sql SECURITY DEFINER
SET search_path = lab, public, pg_temp AS $$
  SELECT COALESCE(jsonb_agg(to_jsonb(v) - 'room_id' - 'round_id'
         ORDER BY v.round_no, v.attempt, v.team_no, array_position(lab.roles(), v.role), v.week), '[]'::jsonb)
  FROM lab.v_decision_audit v WHERE v.room_id = lab.teacher_room(p_teacher) $$;

-- ---------------------------------------------------------------- PRIVILEGES
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
END $$;
REVOKE ALL ON SCHEMA lab FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA lab FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA lab FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA lab FROM PUBLIC, anon, authenticated;
DO $$ DECLARE f record; BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
           WHERE n.nspname='public' AND p.proname LIKE 'bg\_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig);
  END LOOP;
END $$;
NOTIFY pgrst, 'reload schema';
