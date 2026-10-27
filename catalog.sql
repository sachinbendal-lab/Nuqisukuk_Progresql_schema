CREATE OR REPLACE PROCEDURE "catalog"."get_risk_profile_questions"(
    INOUT p_questions REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN p_questions FOR
        SELECT id, question, question_number, options
        FROM "catalog"."risk_profile_question"
        ORDER BY question_number ASC;
END;
$$;

--function - submitRiskProfile

CREATE OR REPLACE PROCEDURE "catalog"."submit_risk_profile"(
    IN  p_customer_number TEXT,
    IN  p_answers JSONB,
    OUT p_result JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_input JSONB;
    v_question risk_profile_question%ROWTYPE;
    v_option JSONB;
    v_answer TEXT;
    v_score INTEGER;
    v_total_score INTEGER := 0;
    v_validated_answers JSONB := '[]'::JSONB;
    v_grid risk_profile_score_grid%ROWTYPE;
    v_profile_id TEXT;
    v_profile_risk_level TEXT;
    v_description TEXT;
    v_min_score INTEGER;
    v_max_score INTEGER;
    v_saved_profile RECORD;
BEGIN
    IF p_answers IS NULL
       OR jsonb_typeof(p_answers) <> 'array'
       OR jsonb_array_length(p_answers) = 0 THEN
        RAISE EXCEPTION 'Answers array is required';
    END IF;

    FOR v_input IN SELECT value FROM jsonb_array_elements(p_answers)
    LOOP
        IF NULLIF(v_input->>'question_id', '') IS NULL
           OR NULLIF(v_input->>'answer', '') IS NULL THEN
            RAISE EXCEPTION 'Each answer must have question_id and answer fields';
        END IF;

        SELECT *
        INTO v_question
        FROM "catalog"."risk_profile_question"
        WHERE id = v_input->>'question_id';

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Question with id % not found', v_input->>'question_id';
        END IF;

        v_answer := v_input->>'answer';
        v_score := 0;

        IF jsonb_typeof(v_question.options) <> 'array' THEN
            RAISE EXCEPTION 'Invalid options format for question %', v_question.id;
        END IF;

        IF jsonb_array_length(v_question.options) > 0 THEN
            SELECT opt
            INTO v_option
            FROM jsonb_array_elements(v_question.options) AS opt
            WHERE lower(opt->>'answer') = lower(v_answer)
            LIMIT 1;

            IF FOUND THEN
                v_score := COALESCE((v_option->>'score')::INTEGER, 0);
            ELSE
                RAISE EXCEPTION 'Invalid answer for question %', v_question.question_number;
            END IF;
        END IF;

        v_total_score := v_total_score + v_score;

        v_validated_answers := v_validated_answers || jsonb_build_array(
            jsonb_build_object(
                'question_id', v_question.id,
                'question', v_question.question,
                'question_number', v_question.question_number,
                'answer', v_answer,
                'score', v_score
            )
        );
    END LOOP;

    SELECT *
    INTO v_grid
    FROM "catalog"."risk_profile_score_grid"
    WHERE v_total_score >= min_score
      AND (max_score IS NULL OR v_total_score <= max_score)
    ORDER BY min_score ASC
    LIMIT 1;

    IF NOT FOUND AND v_total_score > 100 THEN
        SELECT *
        INTO v_grid
        FROM "catalog"."risk_profile_score_grid"
        WHERE risk_level = 'AGGRESSIVE'
        LIMIT 1;
    END IF;

    IF NOT FOUND THEN
        SELECT *
        INTO v_grid
        FROM "catalog"."risk_profile_score_grid"
        WHERE risk_level = 'CONSERVATIVE'
        LIMIT 1;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Risk profile score grid not configured';
    END IF;

    INSERT INTO "catalog"."user_risk_profile" (
        id,
        customer_number,
        total_score,
        risk_level,
        risk_profile_id,
        answers,
        description,
        is_active,
        created_at,
        updated_at
    )
    VALUES (
        md5(random()::TEXT || clock_timestamp()::TEXT),
        p_customer_number,
        v_total_score,
        v_grid.risk_level,
        v_grid.id,
        v_validated_answers,
        COALESCE(v_grid.description, ''),
        TRUE,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (customer_number)
    DO UPDATE SET
        total_score = EXCLUDED.total_score,
        risk_level = EXCLUDED.risk_level,
        risk_profile_id = EXCLUDED.risk_profile_id,
        answers = EXCLUDED.answers,
        description = EXCLUDED.description,
        is_active = TRUE,
        updated_at = CURRENT_TIMESTAMP
    RETURNING id, customer_number, total_score, risk_level, description,
              answers, created_at, updated_at
    INTO v_saved_profile;

    UPDATE "user"."user"
    SET is_risk_verified = TRUE
    WHERE customer_number = p_customer_number;

    p_result := jsonb_build_object(
        'id', v_saved_profile.id,
        'customer_number', v_saved_profile.customer_number,
        'total_score', v_saved_profile.total_score,
        'risk_level', v_saved_profile.risk_level,
        'description', v_saved_profile.description,
        'answers', v_saved_profile.answers,
        'score_range', jsonb_build_object('min', v_grid.min_score,'max', v_grid.max_score),
        'created_at', v_saved_profile.created_at,
        'updated_at', v_saved_profile.updated_at
    );
END;
$$;

--function - getUserRiskProfile

CREATE OR REPLACE PROCEDURE "catalog"."sp_get_user_risk_profile"(
    IN p_customer_number VARCHAR(191),
    INOUT p_cursor REFCURSOR DEFAULT 'risk_profile_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- 1. Fail fast if no identity mapping parameters are supplied
    IF p_customer_number IS NULL OR BTRIM(p_customer_number) = '' THEN
        RAISE EXCEPTION 'ValidationViolation: Customer number parameter is required.';
    END IF;

    -- 2. Open cursor mapping relational records natively
    -- Leverages explicit left join mechanics matching your exact table layout variables
    OPEN p_cursor FOR
    SELECT 
        urp.id,
        urp.customer_number,
        urp.total_score,
        urp.risk_level,
        urp.answers,
        urp.created_at,
        urp.updated_at,
        COALESCE(urp.description, grid.description, '') AS resolved_description,
        grid.min_score AS score_min,
        grid.max_score AS score_max
    FROM "catalog"."user_risk_profile" urp
    LEFT JOIN "catalog"."risk_profile_score_grid" grid 
        ON urp.risk_level = grid.risk_level
    WHERE urp.customer_number = p_customer_number;

END;
$$;

--function - getAllRiskProfileUsers

CREATE OR REPLACE PROCEDURE "catalog"."get_all_risk_profile_users"(
    IN p_page INTEGER,
    IN p_limit INTEGER,
    IN p_risk_level TEXT,
    IN p_search TEXT,
    IN p_has_risk_profile TEXT,
    IN p_export BOOLEAN,
    OUT p_result JSON
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_page INTEGER := GREATEST(COALESCE(p_page, 1), 1);
    v_limit INTEGER := GREATEST(COALESCE(p_limit, 20), 1);
    v_offset INTEGER;
BEGIN
    v_offset := (v_page - 1) * v_limit;

    WITH base_users AS (
        SELECT
            u.id,
            u."userId",
            u.email,
            u.phone_number,
            u.phone_prefix,
            u.first_name,
            u.last_name,
            u.customer_number,
            u.is_active,
            u.is_kyc_verified,
            u.is_phone_verified,
            u.is_email_verified,
            u.is_risk_verified,
            u.created_at,
            urp.id AS profile_id,
            urp.total_score,
            urp.risk_level::TEXT AS profile_risk_level,
            urp.description AS profile_description,
            urp.answers,
            urp.is_active AS profile_is_active,
            urp.created_at AS profile_created_at,
            urp.updated_at AS profile_updated_at,
            rpsg.id AS grid_id,
            rpsg.risk_level::TEXT AS grid_risk_level,
            rpsg.min_score,
            rpsg.max_score,
            rpsg.description AS grid_description
        FROM "user"."user" u
        LEFT JOIN "catalog"."user_risk_profile" urp
            ON urp.customer_number = u.customer_number
        LEFT JOIN "catalog"."risk_profile_score_grid" rpsg
            ON rpsg.id = urp.risk_profile_id
        WHERE u.is_deleted = FALSE
          AND u.role::TEXT = 'USER'
          AND (
              p_search IS NULL OR p_search = ''
              OR u.email ILIKE '%' || p_search || '%'
              OR u.phone_number ILIKE '%' || p_search || '%'
              OR u.first_name ILIKE '%' || p_search || '%'
              OR u.last_name ILIKE '%' || p_search || '%'
              OR u.customer_number ILIKE '%' || p_search || '%'
          )
          AND (
              p_has_risk_profile IS NULL
              OR p_has_risk_profile NOT IN ('true', 'false')
              OR (p_has_risk_profile = 'false' AND urp.id IS NULL)
              OR (p_has_risk_profile = 'true' AND urp.id IS NOT NULL)
          )
          AND (
              p_risk_level IS NULL
              OR p_risk_level NOT IN ('CONSERVATIVE', 'BALANCED', 'GROWTH', 'AGGRESSIVE')
              OR urp.risk_level::TEXT = p_risk_level
          )
    ),
    counts AS (
        SELECT
            COUNT(*) AS total,
            COUNT(*) FILTER (WHERE profile_id IS NULL) AS no_profile,
            COUNT(*) FILTER (WHERE profile_risk_level = 'CONSERVATIVE') AS conservative,
            COUNT(*) FILTER (WHERE profile_risk_level = 'BALANCED') AS balanced,
            COUNT(*) FILTER (WHERE profile_risk_level = 'GROWTH') AS growth,
            COUNT(*) FILTER (WHERE profile_risk_level = 'AGGRESSIVE') AS aggressive
        FROM base_users
    ),
    paged_users AS (
        SELECT *
        FROM base_users
        ORDER BY created_at DESC
        LIMIT CASE WHEN p_export THEN NULL ELSE v_limit END
        OFFSET CASE WHEN p_export THEN 0 ELSE v_offset END
    )
    SELECT json_build_object(
        'users',
        COALESCE(
            (
                SELECT json_agg(
                    json_build_object(
                        'id', pu.id,
                        'userId', pu."userId",
                        'email', pu.email,
                        'phone_number', pu.phone_number,
                        'phone_prefix', pu.phone_prefix,
                        'first_name', pu.first_name,
                        'last_name', pu.last_name,
                        'customer_number', pu.customer_number,
                        'is_active', pu.is_active,
                        'is_kyc_verified', pu.is_kyc_verified,
                        'is_phone_verified', pu.is_phone_verified,
                        'is_email_verified', pu.is_email_verified,
                        'is_risk_verified', pu.is_risk_verified,
                        'created_at', pu.created_at,
                        'risk_profile',
                        CASE WHEN pu.profile_id IS NULL THEN NULL
                        ELSE json_build_object(
                            'id', pu.profile_id,
                            'total_score', pu.total_score,
                            'risk_level', pu.profile_risk_level,
                            'description', pu.profile_description,
                            'answers', COALESCE(pu.answers, '[]'::JSON),
                            'is_active', pu.profile_is_active,
                            'created_at', pu.profile_created_at,
                            'updated_at', pu.profile_updated_at,
                            'score_grid', CASE WHEN pu.grid_id IS NULL THEN NULL
                            ELSE json_build_object(
                                'id', pu.grid_id,
                                'risk_level', pu.grid_risk_level,
                                'min_score', pu.min_score,
                                'max_score', pu.max_score,
                                'description', pu.grid_description
                            )
                            END
                        )
                        END
                    )
                    ORDER BY pu.created_at DESC
                )
                FROM paged_users pu
            ),
            '[]'::JSON
        ),
        'pagination', json_build_object(
            'total', counts.total,
            'page', v_page,
            'limit', v_limit,
            'totalPages', CEIL(counts.total::NUMERIC / v_limit)
        ),
        'counts', json_build_object(
            'ALL', counts.total,
            'CONSERVATIVE', counts.conservative,
            'BALANCED', counts.balanced,
            'GROWTH', counts.growth,
            'AGGRESSIVE', counts.aggressive,
            'NO_PROFILE', counts.no_profile
        )
    )
    INTO p_result
    FROM counts;
END;
$$;

--function - updateUserRiskProfile

CREATE OR REPLACE PROCEDURE "catalog"."get_risk_profile_jumps_proc"(
    IN p_customer_number TEXT,
    INOUT p_result TEXT DEFAULT NULL
)
AS $$
DECLARE
    v_user_exists BOOLEAN;
    v_total_score INT;
    v_current_risk_level VARCHAR(191);
    v_current_profile_id VARCHAR(191);
    v_calculated_profile_id VARCHAR(191);
    v_is_override BOOLEAN := FALSE;
    v_lower_brackets JSONB := '[]'::jsonb;
    v_upper_brackets JSONB := '[]'::jsonb;
    v_final_data JSONB := '[]'::jsonb;
    v_err_msg TEXT;
BEGIN
    -- 1. Fetch the target user's current risk parameters
    SELECT 
        TRUE, total_score, risk_level, risk_profile_id
    INTO 
        v_user_exists, v_total_score, v_current_risk_level, v_current_profile_id
    FROM "catalog"."user_risk_profile"
    WHERE customer_number = p_customer_number;

    -- Return a clean operational 404 block if no profile exists
    IF v_user_exists IS NULL THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'No existing risk profile found for the user.', 'code', 404)::text;
        RETURN;
    END IF;

    -- 2. Build Lower and Upper brackets arrays using JSONB aggregation loops relative to current level
    SELECT COALESCE(JSONB_AGG(sub), '[]'::jsonb) INTO v_lower_brackets
    FROM (
        SELECT id, risk_level AS name, description, min_score, max_score
        FROM "catalog"."risk_profile_score_grid"
        WHERE min_score < (SELECT min_score FROM "catalog"."risk_profile_score_grid" WHERE risk_level = v_current_risk_level LIMIT 1)
        ORDER BY min_score ASC
    ) sub;

    SELECT COALESCE(JSONB_AGG(sub), '[]'::jsonb) INTO v_upper_brackets
    FROM (
        SELECT id, risk_level AS name, description, min_score, max_score
        FROM "catalog"."risk_profile_score_grid"
        WHERE min_score > (SELECT min_score FROM "catalog"."risk_profile_score_grid" WHERE risk_level = v_current_risk_level LIMIT 1)
        ORDER BY min_score ASC
    ) sub;

    -- 3. Inline Risk Level Calculation check to detect manual overrides
    SELECT id INTO v_calculated_profile_id
    FROM "catalog"."risk_profile_score_grid"
    WHERE v_total_score BETWEEN min_score AND max_score
    LIMIT 1;

    IF v_calculated_profile_id IS NOT NULL AND v_current_profile_id <> v_calculated_profile_id THEN
        v_is_override := TRUE;
    END IF;

    -- 4. Execute conditional branching path logic based on the override condition
    IF v_is_override = TRUE THEN
        -- If overridden, only present lower bracket choices
        v_final_data := v_lower_brackets;
    ELSE
        -- If normal score distribution, prefer 1 step upward + all lower bracket items
        IF JSONB_ARRAY_LENGTH(v_upper_brackets) > 0 THEN
            v_final_data := JSONB_BUILD_ARRAY(v_upper_brackets->0) || v_lower_brackets;
        ELSE
            v_final_data := v_lower_brackets;
        END IF;
    END IF;

    -- 5. Build and return pre-serialized clean response payload text string
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'Risk profile brackets fetched successfully.',
        'data', v_final_data,
        'total_score', v_total_score
    )::text;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'An unexpected error occurred.', 'details', v_err_msg, 'code', 500)::text;
END;
$$ LANGUAGE plpgsql;

--function - updateUserRiskProfile

CREATE OR REPLACE PROCEDURE "catalog"."update_user_risk_profile_proc"(
    IN p_customer_number TEXT,
    IN p_risk_profile_id TEXT,
    INOUT p_result TEXT DEFAULT NULL
)
AS $$
DECLARE
    v_user_exists BOOLEAN;
    v_profile_exists BOOLEAN;
    v_current_risk_level VARCHAR(191);
    v_new_risk_level VARCHAR(191);
    v_current_index INT;
    v_new_index INT;
    v_updated_profile JSON;
    v_current_time TIMESTAMP(3) WITHOUT TIME ZONE := NOW()::timestamp(3);
    v_err_msg TEXT;
BEGIN
    -- 1. Verify and fetch the user's current risk placement metrics
    SELECT 
        TRUE, risk_level 
    INTO 
        v_user_exists, v_current_risk_level
    FROM "catalog"."user_risk_profile"
    WHERE customer_number = p_customer_number;

    IF v_user_exists IS NULL THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'User risk profile not found.', 'code', 404)::text;
        RETURN;
    END IF;

    -- 2. Verify that the requested new target profile ID exists inside the scoring grid matrix
    SELECT 
        TRUE, risk_level 
    INTO 
        v_profile_exists, v_new_risk_level
    FROM "catalog"."risk_profile_score_grid"
    WHERE id = p_risk_profile_id;

    IF v_profile_exists IS NULL THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'The specified risk profile does not exist.', 'code', 404)::text;
        RETURN;
    END IF;

    -- 3. Calculate sequence order index values using a conditional array mapping simulation
    v_current_index := CASE v_current_risk_level
        WHEN 'CONSERVATIVE' THEN 0
        WHEN 'BALANCED'     THEN 1
        WHEN 'GROWTH'       THEN 2
        WHEN 'AGGRESSIVE'   THEN 3
        ELSE -1
    END;

    v_new_index := CASE v_new_risk_level
        WHEN 'CONSERVATIVE' THEN 0
        WHEN 'BALANCED'     THEN 1
        WHEN 'GROWTH'       THEN 2
        WHEN 'AGGRESSIVE'   THEN 3
        ELSE -1
    END;

    -- Safety validation drop block for unmapped states
    IF v_current_index = -1 OR v_new_index = -1 THEN
        p_result := JSON_BUILD_OBJECT(
            'success', FALSE, 
            'error', 'Invalid risk levels found for current or new profile.',
            'code', 400
        )::text;
        RETURN;
    END IF;

    -- 4. BUSINESS RULE ENGINE ENFORCEMENT: Users can jump any level lower, but only 1 step higher max
    IF v_new_index > (v_current_index + 1) THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'Users can only jump one level higher in risk profiles.', 'code', 400)::text;
        RETURN;
    END IF;

    -- 5. Commit atomic adjustments down to the storage tier
    UPDATE "catalog"."user_risk_profile"
    SET 
        risk_profile_id = p_risk_profile_id,
        risk_level = v_new_risk_level,
        updated_at = v_current_time
    WHERE customer_number = p_customer_number;

    -- 6. Aggregate data metrics and pull relation descriptions for response mapping consistency
    SELECT JSON_BUILD_OBJECT(
        'id', urp.id,
        'customer_number', urp.customer_number,
        'total_score', urp.total_score,
        'risk_level', urp.risk_level,
        'risk_profile_id', urp.risk_profile_id,
        'description', rpsg.description,
        'updated_at', TO_CHAR(urp.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    ) INTO v_updated_profile
    FROM "catalog"."user_risk_profile" urp
    LEFT JOIN "catalog"."risk_profile_score_grid" rpsg ON urp.risk_profile_id = rpsg.id
    WHERE urp.customer_number = p_customer_number;

    -- 7. Parse output parameters object array payload
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'User risk profile updated successfully.',
        'data', JSON_BUILD_OBJECT('risk_profile', v_updated_profile),
        'meta_log_info', 'from ' || v_current_risk_level || ' to ' || v_new_risk_level
    )::text;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'An unexpected error occurred.', 'details', v_err_msg, 'code', 500)::text;
END;
$$ LANGUAGE plpgsql;

--function - getGenders

CREATE OR REPLACE PROCEDURE "catalog"."sp_create_on_hold_reason"(
    IN p_reason_name TEXT,
    IN p_template_html TEXT,
    IN p_subject VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_template_id INTEGER;
BEGIN
    IF p_reason_name IS NULL
       OR BTRIM(p_reason_name) = '' THEN
        RAISE EXCEPTION 'reason_name is required';
    END IF;

    IF p_template_html IS NULL
       OR BTRIM(p_template_html) = '' THEN
        RAISE EXCEPTION 'template_html is required';
    END IF;

    IF p_subject IS NULL
       OR BTRIM(p_subject) = '' THEN
        RAISE EXCEPTION 'subject is required';
    END IF;

    /*
      Reuse an existing identical template/reason configuration.
    */
    SELECT id
    INTO v_template_id
    FROM "catalog"."reason_templates"
    WHERE reason = p_reason_name
      AND html_content = p_template_html
      AND subject = p_subject
      AND context_table = 'bank_verification'
      AND reason_type = 'ON_HOLD'
    LIMIT 1;

    IF v_template_id IS NULL THEN

        INSERT INTO "catalog"."reason_templates"
        (
            ref_id,
            subject,
            reason,
            html_content,
            context_table,
            reason_type,
            status,
            created_at,
            updated_at
        )
        VALUES
        (
            'BANK_ON_HOLD_' ||
            REPLACE(gen_random_uuid()::TEXT, '-', ''),
            p_subject,
            p_reason_name,
            p_template_html,
            'bank_verification',
            'ON_HOLD',
            'Active',
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
        )
        RETURNING id INTO v_template_id;

    END IF;

    OPEN p_cursor FOR
    SELECT
        rt.id,
        rt.ref_id,
        rt.reason AS reason_name,
        rt.subject,
        rt.html_content AS html_template,
        rt.context_table,
        rt.reason_type,
        rt.status,
        rt.created_at,
        rt.updated_at
    FROM "catalog"."reason_templates" rt
    WHERE rt.id = v_template_id;

END;
$$;

64.
/* ============================================================
   SP NAME        : sp_get_on_hold_reasons

   NODE.JS FUNCTION : getOnHoldReasons()

   PURPOSE :
   Return active ON_HOLD reasons for dropdown.

   ACCESS :
   Authenticated users

   ============================================================ */

DROP PROCEDURE IF EXISTS sp_get_on_hold_reasons(
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "catalog"."sp_get_on_hold_reasons"(
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN p_cursor FOR
    SELECT
        rt.id,
        rt.reason AS reason_name
    FROM "catalog"."reason_templates" rt
    WHERE rt.reason_type = 'ON_HOLD'
      AND LOWER(COALESCE(rt.status, '')) = 'active'
    ORDER BY rt.reason ASC;

END;
$$;

65.
/* ============================================================
   SP NAME        : sp_get_all_on_hold_reasons

   NODE.JS FUNCTION : getAllOnHoldReasons()

   PURPOSE :
   Admin listing of ON_HOLD reasons with template information.

   ACCESS :
   ADMIN / SUPER_ADMIN

   ============================================================ */

DROP PROCEDURE IF EXISTS sp_get_all_on_hold_reasons(
    BOOLEAN,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "catalog"."sp_get_all_on_hold_reasons"(
    IN p_include_inactive BOOLEAN DEFAULT FALSE,
    INOUT p_cursor REFCURSOR DEFAULT 'on_hold_reasons_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Use reason_templates from the config schema
    SET LOCAL search_path TO config, public;

    OPEN p_cursor FOR
    SELECT
        rt."id",
        rt."reason" AS reason_name,

        CASE
            WHEN LOWER(COALESCE(rt."status", '')) = 'active'
            THEN TRUE
            ELSE FALSE
        END AS is_active,

        rt."created_at" AS "createdAt",
        rt."updated_at" AS "updatedAt",

        rt."id" AS template_id,
        rt."subject",
        rt."html_content" AS html_template

    FROM "catalog"."reason_templates" AS rt
    WHERE rt."reason_type" = 'ON_HOLD'
      AND (
          p_include_inactive = TRUE
          OR LOWER(COALESCE(rt."status", '')) = 'active'
      )
    ORDER BY rt."created_at" DESC;
END;
$$;

66.
/* ============================================================
   SP NAME        : sp_get_on_hold_reason_by_id

   NODE.JS FUNCTION : getOnHoldReasonById()

   PURPOSE :
   Fetch one ON_HOLD reason and its template.

   ACCESS :
   ADMIN / SUPER_ADMIN

   ============================================================ */

DROP PROCEDURE IF EXISTS sp_get_on_hold_reason_by_id(
    INTEGER,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "catalog"."sp_get_on_hold_reason_by_id"(
    IN p_id INTEGER,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_id IS NULL THEN
        RAISE EXCEPTION 'Invalid reason ID';
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM "catalog"."reason_templates"
        WHERE id = p_id
          AND reason_type = 'ON_HOLD'
    ) THEN
        RAISE EXCEPTION 'ON_HOLD reason not found';
    END IF;

    OPEN p_cursor FOR
    SELECT
        rt.id,
        rt.ref_id,
        rt.reason AS reason_name,
        rt.subject,
        rt.html_content AS html_template,
        rt.context_table,
        rt.reason_type,
        rt.status,

        CASE
            WHEN LOWER(COALESCE(rt.status, '')) = 'active'
            THEN TRUE
            ELSE FALSE
        END AS is_active,

        rt.created_at,
        rt.updated_at

    FROM "catalog"."reason_templates" rt
    WHERE rt.id = p_id
      AND rt.reason_type = 'ON_HOLD';

END;
$$;

67
/* ============================================================
   SP NAME        : sp_update_on_hold_reason

   NODE.JS FUNCTION : updateOnHoldReason()

   PURPOSE :
   Update ON_HOLD reason/template configuration.

   ACCESS :
   ADMIN / SUPER_ADMIN

   IMPORTANT :
   *_supplied flags distinguish:
       omitted field
   from:
       explicitly supplied value

   ============================================================ */

DROP PROCEDURE IF EXISTS sp_update_on_hold_reason(
    INTEGER,
    TEXT,
    BOOLEAN,
    TEXT,
    BOOLEAN,
    VARCHAR,
    BOOLEAN,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "catalog"."sp_update_on_hold_reason"(
    IN p_id INTEGER,

    IN p_reason_name TEXT,
    IN p_reason_name_supplied BOOLEAN,

    IN p_template_html TEXT,
    IN p_template_html_supplied BOOLEAN,

    IN p_subject VARCHAR(191),
    IN p_subject_supplied BOOLEAN,

    IN p_is_active BOOLEAN,
    IN p_is_active_supplied BOOLEAN,

    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_id IS NULL THEN
        RAISE EXCEPTION 'Invalid reason ID';
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM "catalog"."reason_templates"
        WHERE id = p_id
          AND reason_type = 'ON_HOLD'
    ) THEN
        RAISE EXCEPTION 'ON_HOLD reason not found';
    END IF;

    UPDATE "catalog"."reason_templates"
    SET
        reason =
            CASE
                WHEN p_reason_name_supplied
                THEN p_reason_name
                ELSE reason
            END,

        html_content =
            CASE
                WHEN p_template_html_supplied
                THEN p_template_html
                ELSE html_content
            END,

        subject =
            CASE
                WHEN p_subject_supplied
                THEN p_subject
                ELSE subject
            END,

        status =
            CASE
                WHEN p_is_active_supplied
                THEN
                    CASE
                        WHEN p_is_active = TRUE
                        THEN 'Active'
                        ELSE 'Inactive'
                    END
                ELSE status
            END,

        updated_at = CURRENT_TIMESTAMP

    WHERE id = p_id
      AND reason_type = 'ON_HOLD';

    OPEN p_cursor FOR
    SELECT
        rt.id,
        rt.ref_id,
        rt.reason AS reason_name,
        rt.subject,
        rt.html_content AS html_template,
        rt.context_table,
        rt.reason_type,
        rt.status,

        CASE
            WHEN LOWER(COALESCE(rt.status, '')) = 'active'
            THEN TRUE
            ELSE FALSE
        END AS is_active,

        rt.created_at,
        rt.updated_at

    FROM "catalog"."reason_templates" rt
    WHERE rt.id = p_id;

END;
$$;

68
/* ============================================================
   SP NAME        : sp_delete_on_hold_reason

   NODE.JS FUNCTION : deleteOnHoldReason()

   PURPOSE :
   Soft-delete an ON_HOLD reason.

   ACCESS :
   ADMIN / SUPER_ADMIN

   IMPORTANT :
   No DELETE is performed.
   status is changed to Inactive.

   ============================================================ */

DROP PROCEDURE IF EXISTS sp_delete_on_hold_reason(
    INTEGER,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "catalog"."sp_delete_on_hold_reason"(
    IN p_id INTEGER,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_id IS NULL THEN
        RAISE EXCEPTION 'Invalid reason ID';
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM "catalog"."reason_templates"
        WHERE id = p_id
          AND reason_type = 'ON_HOLD'
    ) THEN
        RAISE EXCEPTION 'ON_HOLD reason not found';
    END IF;

    UPDATE "catalog"."reason_templates"
    SET
        status = 'Inactive',
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id
      AND reason_type = 'ON_HOLD';

    OPEN p_cursor FOR
    SELECT
        rt.id,
        rt.reason AS reason_name,
        rt.status,
        FALSE AS is_active,
        rt.updated_at
    FROM "catalog"."reason_templates" rt
    WHERE rt.id = p_id;

END;
$$;
69.
/* ============================================================
   SP NAME        : sp_send_on_hold_reminder

   NODE.JS FUNCTION : sendOnHoldReminder()

   PURPOSE :
   Validate an ON_HOLD bank verification and return the
   information required by Node.js to send the reminder email.

   ACCESS :
   ADMIN / SUPER_ADMIN

   IMPORTANT :
   This SP DOES NOT send email.
   Node.js remains responsible for sendEmail().

   ============================================================ */

DROP PROCEDURE IF EXISTS sp_send_on_hold_reminder(
    INTEGER,
    REFCURSOR
);
