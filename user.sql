--function - checkEmail

CREATE OR REPLACE PROCEDURE "user"."check_email"(
    IN p_email text
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Internal processing variables
    v_user_is_active boolean;
    v_user_is_email_verified boolean;
    v_staging_id text;
    v_staging_current_step integer;
BEGIN
    -- Trim inputs and convert empty strings to NULL
    p_email := NULLIF(trim(p_email), '');

    -------------------------------------------------------------------------
    -- [CHECKPOINT 1]: Input Email Validation
    -------------------------------------------------------------------------
    IF p_email IS NULL THEN
        RAISE EXCEPTION 'Email is required.';
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 2]: Main User Table Check
    -------------------------------------------------------------------------
    SELECT 
        u.is_active,
        u.is_email_verified
    INTO 
        v_user_is_active,
        v_user_is_email_verified
    FROM "user"."user" u
    WHERE u.email = p_email
      AND u.is_deleted = false
    LIMIT 1;

    -- If record is found in the user table
    IF FOUND THEN
        RAISE NOTICE 'Success: Email already exists. Action: LOGIN';
        -- Optional: You can log or raise an informational notice with user status if needed
        RETURN;
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 3]: Registration Staging Table Check
    -------------------------------------------------------------------------
    -- Extracting current_step from JSONB using ->> operator
    SELECT 
        rs.id,
        CAST(rs.metadata->>'current_step' AS integer)
    INTO 
        v_staging_id,
        v_staging_current_step
    FROM "user"."registration_staging" rs
    WHERE rs.email = p_email
      AND rs.expires_at > now()
    LIMIT 1;

    -- If record is found in the staging table
    IF FOUND THEN
        RAISE NOTICE 'Success: Registration in progress. Action: CONTINUE_REGISTRATION';
        RETURN;
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 4]: Error Flash if Email is Nowhere to be Found
    -------------------------------------------------------------------------
    RAISE EXCEPTION 'Email not found in active users or pending registrations.';
END;
$$;

--function - checkPhone

CREATE OR REPLACE PROCEDURE "user"."check_phone"(
    IN p_phone_number text
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Internal processing variables
    v_user_is_active boolean;
    v_user_is_phone_verified boolean;
    v_staging_id text;
    v_staging_current_step integer;
BEGIN
    -- Trim inputs and convert empty strings to NULL
    p_phone_number := NULLIF(trim(p_phone_number), '');

    -------------------------------------------------------------------------
    -- [CHECKPOINT 1]: Input Phone Validation
    -------------------------------------------------------------------------
    IF p_phone_number IS NULL THEN
        RAISE EXCEPTION 'Phone number is required.';
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 2]: Main User Table Check
    -------------------------------------------------------------------------
    SELECT 
        u.is_active,
        COALESCE(u.is_phone_verified, false)
    INTO 
        v_user_is_active,
        v_user_is_phone_verified
    FROM "user"."user" u
    WHERE u.phone_number = p_phone_number
      AND u.is_deleted = false
    LIMIT 1;

    -- If record is found in the user table
    IF FOUND THEN
        RAISE NOTICE 'Success: Phone number already exists. Action: LOGIN';
        RETURN;
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 3]: Registration Staging Table Check
    -------------------------------------------------------------------------
    SELECT 
        rs.id,
        CAST(rs.metadata->>'current_step' AS integer)
    INTO 
        v_staging_id,
        v_staging_current_step
    FROM "user"."registration_staging" rs
    WHERE rs.phone_number = p_phone_number
      AND rs.expires_at > now()
    LIMIT 1;

    -- If record is found in the staging table
    IF FOUND THEN
        RAISE NOTICE 'Success: Registration in progress. Action: CONTINUE_REGISTRATION';
        RETURN;
    END IF;

--function - Registeruser

CREATE OR REPLACE PROCEDURE "user"."register_user"(
    IN p_email text,
    IN p_phone_number text,
    IN p_phone_prefix text,
    IN p_otp_hash text
)
LANGUAGE plpgsql AS $$
DECLARE
    -- Internal variables for processing
    v_metadata text;
    v_staging_id text;
    v_existing_id text;
    v_is_existing_staging boolean := false;
BEGIN
    -- Trim inputs and convert empty strings to NULL
    p_email := NULLIF(trim(p_email), '');
    p_phone_number := NULLIF(trim(p_phone_number), '');
    p_phone_prefix := NULLIF(trim(p_phone_prefix), '');
    p_otp_hash := NULLIF(trim(p_otp_hash), '');

    -------------------------------------------------------------------------
    -- [CHECKPOINT 1]: Input Data Validation
    -------------------------------------------------------------------------
    IF p_email IS NULL AND p_phone_number IS NULL THEN
        RAISE EXCEPTION 'Validation Failed: Email or phone number is required';
    END IF;

    IF p_phone_number IS NOT NULL AND p_phone_prefix IS NULL THEN
        RAISE EXCEPTION 'Validation Failed: Phone prefix is required';
    END IF;

    IF p_otp_hash IS NULL THEN
        RAISE EXCEPTION 'Validation Failed: OTP Hash is required';
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 2]: Metadata Preparation
    -------------------------------------------------------------------------
    v_metadata := '{"current_step": 1, "step_name": "OTP Verification", "is_otp_verified": false, "otp_attempts": 0}';

    -------------------------------------------------------------------------
    -- [CHECKPOINT 3]: Main Active User Table Check
    -------------------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM "user"."user" u 
        WHERE u.is_deleted = false 
          AND (
            (p_email IS NOT NULL AND u.email = p_email) OR 
            (p_phone_number IS NOT NULL AND u.phone_number = p_phone_number)
          )
    ) THEN
        RAISE EXCEPTION 'Account already exists. Please login.';
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 4]: Clean Up Expired Staging Records
    -------------------------------------------------------------------------
    DELETE FROM "user"."registration_staging" rs 
    WHERE rs.expires_at <= now() 
      AND (
        (p_email IS NOT NULL AND rs.email = p_email) OR 
        (p_phone_number IS NOT NULL AND rs.phone_number = p_phone_number)
      );

    -------------------------------------------------------------------------
    -- [CHECKPOINT 5]: Check For Existing Non-Expired Staging Records
    -------------------------------------------------------------------------
    SELECT id INTO v_existing_id 
    FROM "user"."registration_staging"
    WHERE (p_email IS NOT NULL AND email = p_email)
       OR (p_email IS NULL AND p_phone_number IS NOT NULL AND phone_number = p_phone_number)
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        v_is_existing_staging := true;
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 6]: Execute Insert / Update Block
    -------------------------------------------------------------------------
    IF v_is_existing_staging = true THEN
        ----------------------------------------------------
        -- [UPDATE EXISTING DATA SECTION]
        ----------------------------------------------------
        UPDATE "user"."registration_staging"
        SET phone_number = CASE WHEN p_email IS NOT NULL THEN p_phone_number ELSE phone_number END,
            phone_prefix = p_phone_prefix,
            otp_hash = p_otp_hash, 
            metadata = v_metadata::jsonb, 
            expires_at = now() + interval '24 hours' -- Set to 24 Hours on update
        WHERE id = v_existing_id;
        
        RAISE NOTICE 'Success: Staging data updated successfully for ID %', v_existing_id;
    ELSE
        ----------------------------------------------------
        -- [INSERT NEW DATA SECTION]
        ----------------------------------------------------
        v_staging_id := md5(random()::text || clock_timestamp()::text);
        
        INSERT INTO "user"."registration_staging" (id, email, phone_number, phone_prefix, otp_hash, metadata, expires_at, created_at)
        VALUES (v_staging_id, p_email, p_phone_number, p_phone_prefix, p_otp_hash, v_metadata::jsonb, now() + interval '24 hours', now()); -- Set to 24 Hours on insert
        
        RAISE NOTICE 'Success: New staging data inserted successfully with ID %', v_staging_id;
    END IF;

    RAISE NOTICE 'OTP processed successfully. Step: OTP Verification.';
END;
$$;

--function Registeruser

CREATE OR REPLACE PROCEDURE "user"."update_registration_metadata"(
    IN p_staging_id text,
    IN p_first_name text,
    IN p_last_name text,
    IN p_username text,
    IN p_date_of_birth text DEFAULT NULL,
    IN p_gender text DEFAULT NULL
)
LANGUAGE 'plpgsql'
AS $$
DECLARE
    v_existing_metadata jsonb;
    v_new_data jsonb;
BEGIN
    -- Trim inputs and convert empty strings to NULL
    p_staging_id := NULLIF(trim(p_staging_id), '');
    p_first_name := NULLIF(trim(p_first_name), '');
    p_last_name  := NULLIF(trim(p_last_name), '');
    p_username   := NULLIF(trim(p_username), '');
    p_date_of_birth := NULLIF(trim(p_date_of_birth), '');
    p_gender     := NULLIF(trim(p_gender), '');

    -------------------------------------------------------------------------
    -- [CHECKPOINT 1]: Input Parameters Validation
    -------------------------------------------------------------------------
    IF p_staging_id IS NULL THEN
        RAISE EXCEPTION 'Staging ID is required.';
    END IF;

    IF p_first_name IS NULL THEN
        RAISE EXCEPTION 'First name is required.';
    END IF;

    IF p_last_name IS NULL THEN
        RAISE EXCEPTION 'Last name is required.';
    END IF;

    IF p_username IS NULL THEN
        RAISE EXCEPTION 'Username is required.';
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 2]: Fetch Active Staging Record Metadata
    -------------------------------------------------------------------------
    SELECT metadata INTO v_existing_metadata
    FROM "user"."registration_staging"
    WHERE id = p_staging_id;

    -- If no unexpired registration row exists for this ID
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Registration session not found or session has expired.';
    END IF;

    -- Ensure null-safety for metadata if it was stored empty
    v_existing_metadata := COALESCE(v_existing_metadata, '{}'::jsonb);

    -------------------------------------------------------------------------
    -- [CHECKPOINT 3]: Construct and Merge the Profiles Metadata
    -------------------------------------------------------------------------
    v_new_data := jsonb_build_object(
        'first_name', p_first_name,
        'last_name', p_last_name,
        'username', p_username,
        'date_of_birth', p_date_of_birth,
        'gender', p_gender
    );

    -- Use the || operator to merge new fields securely into the existing JSON block
    v_existing_metadata := v_existing_metadata || v_new_data;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 4]: Execute Table Update Execution
    -------------------------------------------------------------------------
    UPDATE "user"."registration_staging"
    SET metadata = v_existing_metadata
    WHERE id = p_staging_id;
END;
$$; 

-- function - verifyOTP

CREATE OR REPLACE PROCEDURE "user"."verifyotp"(
    IN p_otp_ref text
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Internal processing variables
    v_db_id text;
    v_expires_at timestamp;
BEGIN
    -------------------------------------------------------------------------
    -- [CHECKPOINT 1]: Input Parameters Validation
    -------------------------------------------------------------------------
    IF p_otp_ref IS NULL OR trim(p_otp_ref) = '' THEN
        RAISE EXCEPTION 'OTP Reference (Hash) input parameter is required.';
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 2]: Fetch Records by matching the otp_hash column value
    -------------------------------------------------------------------------
    SELECT id, expires_at 
    INTO v_db_id, v_expires_at
    FROM "user"."registration_staging" 
    WHERE otp_hash = p_otp_ref
    LIMIT 1; -- Semicolon added strictly here to prevent the syntax compile error

    -- If the requested OTP hash target value does not exist inside the table grid
    IF v_db_id IS NULL THEN
        RAISE EXCEPTION 'OTP Hash "%" does not exist in the database staging table.', p_otp_ref;
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 3]: Expiry Session Window Evaluation
    -------------------------------------------------------------------------
    IF v_expires_at <= now() THEN
        RAISE EXCEPTION 'Session expired for this OTP value. Expiry Window: %, Current Timestamp: %', v_expires_at, now();
    END IF;

    -- Informational tracking verification note to the database console log window
    RAISE NOTICE 'Success: Session context found and verified via OTP Hash string value. Staging ID resolved: %', v_db_id;
END;
$$;

--function - resendOTP

CREATE OR REPLACE PROCEDURE "user"."resendotp"(
    IN p_otp_ref text,
    IN p_new_hash text
)
LANGUAGE plpgsql
AS $$
BEGIN
    -------------------------------------------------------------------------
    -- [CHECKPOINT 1]: Input Parameters Validation
    -------------------------------------------------------------------------
    IF p_otp_ref IS NULL OR trim(p_otp_ref) = '' THEN
        RAISE EXCEPTION 'OTP Reference ID is required.';
    END IF;

    IF p_new_hash IS NULL OR trim(p_new_hash) = '' THEN
        RAISE EXCEPTION 'New Hash string value is required.';
    END IF;

    -------------------------------------------------------------------------
    -- [CHECKPOINT 2]: Execute Target Table Update Row Update
    -------------------------------------------------------------------------
    UPDATE "user"."registration_staging"
    SET otp_hash = p_new_hash
    WHERE id = p_otp_ref;

    -- Optional debug status message printed to the console window
    RAISE NOTICE 'Success: Hash updated successfully for Staging ID %', p_otp_ref;
END;
$$;

-- function - acceptTermsAndComplete

CREATE OR REPLACE PROCEDURE "user"."complete_registration"(
	IN p_staging_id text,
	IN p_is_tnc_checked boolean,
	IN p_referral text,
	OUT o_user_id integer,
	OUT o_userid text,
	OUT o_customer_number text,
	OUT o_wallet_id text,
	OUT o_email text,
	OUT o_phone_number text,
	OUT o_phone_prefix text,
	OUT o_first_name text,
	OUT o_last_name text,
	OUT o_username text,
	OUT o_is_phone_verified boolean,
	OUT o_is_email_verified boolean,
	OUT o_is_active boolean,
	OUT o_created_at timestamp without time zone)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_staging registration_staging%ROWTYPE;
    v_metadata JSONB;
    v_kyc_data JSONB;
    v_kyc_status TEXT;
    v_new_user_id INTEGER;
    v_customer_no TEXT;
    v_wallet_id TEXT;
    
    v_generated_user_id TEXT;
    v_generated_wallet_id TEXT;
    v_next_wallet_int_id INTEGER;
BEGIN
    IF p_staging_id IS NULL OR btrim(p_staging_id) = '' THEN
        RAISE EXCEPTION 'Staging ID is required' USING ERRCODE = '22023';
    END IF;

    IF p_is_tnc_checked IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'Terms and conditions must be accepted' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_staging FROM "user"."registration_staging" WHERE id = p_staging_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Registration session not found' USING ERRCODE = 'P0002';
    END IF;

    v_metadata := COALESCE(v_staging.metadata::JSONB, '{}'::JSONB);

    IF NULLIF(v_metadata->>'first_name', '') IS NULL OR NULLIF(v_metadata->>'last_name', '') IS NULL THEN
        RAISE EXCEPTION 'Please complete all required steps' USING ERRCODE = '22023';
    END IF;

    IF v_staging.phone_number IS NOT NULL AND EXISTS (
        SELECT 1 FROM "user"."user" WHERE phone_number = v_staging.phone_number AND is_deleted = FALSE
    ) THEN
        RAISE EXCEPTION 'An account with this phone number already exists' USING ERRCODE = '23505';
    END IF;

    v_generated_user_id := 'cmj' || substr(md5(random()::text), 1, 22);

    INSERT INTO "user"."user" (
        "userId", email, username, first_name, last_name, gender, phone_number, phone_prefix,
        is_tnc_checked, referral, role, is_phone_verified, is_email_verified, is_active
    )
    VALUES (
        v_generated_user_id,
        v_staging.email,
        COALESCE(v_metadata->>'username', ''),
        v_metadata->>'first_name',
        v_metadata->>'last_name',
        NULLIF(v_metadata->>'gender', '')::gender_enum,
        v_staging.phone_number,
        v_staging.phone_prefix,
        p_is_tnc_checked,
        NULLIF(p_referral, ''),
        'USER',
        (v_staging.phone_number IS NOT NULL),
        (v_staging.email IS NOT NULL),
        TRUE
    )
    RETURNING id INTO v_new_user_id;

    v_customer_no := 'NUQI' || lpad(v_new_user_id::TEXT, 8, '0');

    UPDATE "user"."user" SET customer_number = v_customer_no, updated_at = CURRENT_TIMESTAMP WHERE id = v_new_user_id;

    SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_wallet_int_id FROM "payments"."wallet";

    v_generated_wallet_id := 'cmi' || substr(md5(random()::text), 1, 22);

    INSERT INTO "payments"."wallet" (
        id, "walletId", customer_number, balance, currency, status, is_active, created_at, updated_at
    )
    VALUES (
        v_next_wallet_int_id, 
        v_generated_wallet_id, 
        v_customer_no, 
        0.00, 
        'USD', 
        'ACTIVE', 
        TRUE,
        CURRENT_TIMESTAMP, 
        CURRENT_TIMESTAMP  
    )
    RETURNING "walletId" INTO v_wallet_id;

    v_kyc_status := v_metadata->>'kyc_status';
    v_kyc_data := COALESCE(v_metadata->'kyc_data', '{}'::JSONB);

    IF v_kyc_status IS NOT NULL AND v_kyc_status <> '' THEN
        INSERT INTO "kyc"."kyc" (
            user_id, customer_number, full_name, date_of_birth, gender, address,
            document_type, document_number, reference_id, status, decline_reason,
            facia_response, verified_at
        )
        VALUES (
            v_new_user_id,
            v_customer_no,
            v_kyc_data->>'full_name',
            NULLIF(v_kyc_data->>'date_of_birth', '')::TIMESTAMP,
            NULLIF(v_kyc_data->>'gender', '')::gender_enum,
            v_kyc_data->>'address',
            v_kyc_data->>'document_type',
            v_kyc_data->>'document_number',
            v_metadata->>'kyc_reference_id',
            v_kyc_status,
            v_metadata->>'kyc_decline_reason',
            COALESCE(v_metadata->'facia_response', '{}'::JSONB),
            NULLIF(v_metadata->>'kyc_verified_at', '')::TIMESTAMP
        );

        UPDATE "user"."user" SET
            is_kyc_verified = (v_kyc_status = 'ACCEPTED'),
            kyc_status = CASE
                WHEN v_kyc_status = 'ACCEPTED' THEN 'VERIFIED'
                WHEN v_kyc_status = 'DECLINED' THEN 'DECLINED'
                ELSE v_kyc_status
            END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_new_user_id;
    END IF;

    DELETE FROM "user"."registration_staging" WHERE id = p_staging_id;

    SELECT id, "userId", email, phone_number, phone_prefix, first_name, last_name, username, is_phone_verified, is_email_verified, is_active, created_at
    INTO o_user_id, o_userid, o_email, o_phone_number, o_phone_prefix, o_first_name, o_last_name, o_username, o_is_phone_verified, o_is_email_verified, o_is_active, o_created_at
    FROM "user"."user"
    WHERE id = v_new_user_id;

    o_customer_number := v_customer_no;
    o_wallet_id := v_wallet_id;
END;
$BODY$;

--function - acceptTermsAndComplete

CREATE OR REPLACE PROCEDURE "user"."create_refresh_token_proc"(
    IN p_token_hash VARCHAR(191),
    IN p_user_id VARCHAR(191),
    IN p_user_type VARCHAR(191),
    IN p_family_id VARCHAR(191),
    IN p_token_version INT,
    IN p_device_info JSONB,
    INOUT p_result JSON DEFAULT NULL
)
AS $$
DECLARE
    v_user_exists BOOLEAN;
    v_generated_id VARCHAR(191); -- Variable to hold our auto-generated string UUID
    v_err_msg TEXT;
    v_current_time TIMESTAMP(3) WITHOUT TIME ZONE := NOW()::timestamp(3);
    v_expiry_time TIMESTAMP(3) WITHOUT TIME ZONE := (NOW() + INTERVAL '30 days')::timestamp(3);
BEGIN
    -- 1. Verify user context
    SELECT EXISTS (
        SELECT 1 FROM "user"."user" 
        WHERE "userId" = p_user_id AND "is_deleted" = FALSE
    ) INTO v_user_exists;

    IF NOT v_user_exists THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'Cannot create token. User not found or deleted.', 'code', 404);
        RETURN;
    END IF;

    -- 2. Automatically generate a compliant 36-character string UUID matching your table rows
    v_generated_id := md5(random()::text || clock_timestamp()::text)::uuid::text;

    -- 3. Insert into the refresh_tokens table using the auto-generated ID
    INSERT INTO "user"."refresh_tokens" (
        id,                -- Populated automatically
        token_hash,
        user_id,
        user_type,
        family_id,
        token_version,
        device_info,
        expires_at,
        is_used,
        revoked_at, 
        revoked_reason,
        created_at 
    ) VALUES ( 
        v_generated_id, 
        p_token_hash, 
        p_user_id, 
        p_user_type, 
        p_family_id, 
        p_token_version, 
        p_device_info, 
        v_expiry_time, 
        FALSE,  
        NULL, 
        NULL, 
        v_current_time 
    );

    -- 4. Return the payload with the auto-generated ID back to the application layer
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'Refresh token session created successfully.',
        'tokenId', v_generated_id,
        'expiresAt', v_expiry_time
    );

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', v_err_msg, 'code', 500);
END;
$$ LANGUAGE plpgsql;

--function - saveBasicInfo

CREATE OR REPLACE PROCEDURE "user"."save_basic_info"(
    IN p_staging_id    TEXT,
    IN p_first_name    TEXT,
    IN p_last_name     TEXT,
    IN p_date_of_birth TEXT,
    IN p_username      TEXT,
    IN p_phone_prefix  TEXT,
    IN p_phone_number  TEXT,
    IN p_gender        TEXT,
    IN p_referral      TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_metadata JSONB;
    v_old_phone_number TEXT;
    v_old_phone_prefix TEXT;
    v_username_exists BOOLEAN;
BEGIN
    -- 1. Input Validation (Required Fields Check)
    IF p_staging_id IS NULL OR btrim(p_staging_id) = ''
       OR p_first_name IS NULL OR btrim(p_first_name) = ''
       OR p_last_name IS NULL OR btrim(p_last_name) = '' THEN
        RAISE EXCEPTION 'Staging ID, first name and last name are required' USING ERRCODE = '22023';
    END IF;

    -- 2. Fetch Existing Data from Staging Table (With Row Lock)
    SELECT metadata::JSONB, phone_number, phone_prefix
      INTO v_metadata, v_old_phone_number, v_old_phone_prefix
      FROM "user"."registration_staging"
     WHERE id = p_staging_id
     FOR UPDATE;

    -- Raise exception if session is not found
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Registration session not found' USING ERRCODE = 'P0002';
    END IF;

    -- [OTP CHECK CONDITION REMOVED FROM HERE] --

    -- 3. Check if Username Already Exists
    IF p_username IS NOT NULL AND btrim(p_username) <> '' THEN
        SELECT EXISTS (
            SELECT 1 
            FROM "user"."user" 
            WHERE username = p_username 
              AND is_deleted = FALSE
        ) INTO v_username_exists;

        IF v_username_exists THEN
            RAISE EXCEPTION 'Username already taken' USING ERRCODE = '23505';
        END IF;
    END IF;

    -- 4. Construct and Merge JSON Metadata Object
    v_metadata := COALESCE(v_metadata, '{}'::JSONB) || jsonb_build_object(
        'current_step', 3,
        'step_name', 'Terms Acceptance',
        'first_name', p_first_name,
        'last_name', p_last_name,
        'date_of_birth', p_date_of_birth,
        'username', p_username,
        'phone_prefix', p_phone_prefix,
        'phone_number', p_phone_number,
        'gender', p_gender,
        'referral', p_referral
    );

    -- 5. Update Staging Table with New Information
    UPDATE "user"."registration_staging"
       SET phone_number = COALESCE(NULLIF(btrim(p_phone_number), ''), v_old_phone_number),
           phone_prefix = COALESCE(NULLIF(btrim(p_phone_prefix), ''), v_old_phone_prefix),
           metadata = v_metadata
     WHERE id = p_staging_id;

END;
$$;

--function - getRegistrationStatus

CREATE OR REPLACE PROCEDURE "user"."get_registration_status"(
    -- Input parameters
    IN  p_email           TEXT,
    IN  p_phone_number    TEXT,
    IN  p_staging_id      TEXT,
    -- Output parameters to return data
    OUT o_success         BOOLEAN,
    OUT o_http_status     INTEGER,
    OUT o_message         TEXT,
    OUT o_staging_id      TEXT,
    OUT o_current_step    INTEGER,
    OUT o_step_name       TEXT,
    OUT o_is_otp_verified TEXT,
    OUT o_has_basic_info  BOOLEAN,
    OUT o_metadata        JSONB,
    OUT o_should_start_new BOOLEAN
) 
LANGUAGE plpgsql AS $$
DECLARE
    v_id          TEXT;
    v_email       TEXT;
    v_phone       TEXT;
    v_expires_at  TIMESTAMP;
    v_local_metadata JSONB; 
BEGIN
    -- 1. Input Validation: Check if all inputs are missing
    IF (p_email IS NULL OR btrim(p_email) = '')
       AND (p_phone_number IS NULL OR btrim(p_phone_number) = '')
       AND (p_staging_id IS NULL OR btrim(p_staging_id) = '') THEN
        
        o_success          := FALSE;
        o_http_status      := 400;
        o_message          := 'Email, phone number, or staging_id is required';
        o_staging_id       := NULL;
        o_current_step     := NULL;
        o_step_name        := NULL;
        o_is_otp_verified  := NULL;
        o_has_basic_info   := FALSE;
        o_metadata         := NULL;
        o_should_start_new := FALSE;
        RETURN;
    END IF;

    -- 2. Fetch the session based on provided parameters
    IF p_staging_id IS NOT NULL AND btrim(p_staging_id) <> '' THEN
        SELECT id, email, phone_number, expires_at, metadata::JSONB
          INTO v_id, v_email, v_phone, v_expires_at, v_local_metadata
          FROM "user"."registration_staging"
         WHERE id = p_staging_id
         LIMIT 1;
    ELSE
        SELECT id, email, phone_number, expires_at, metadata::JSONB
          INTO v_id, v_email, v_phone, v_expires_at, v_local_metadata
          FROM "user"."registration_staging"
         WHERE (p_email IS NOT NULL AND btrim(p_email) <> '' AND email = p_email)
            OR (p_phone_number IS NOT NULL AND btrim(p_phone_number) <> '' AND phone_number = p_phone_number)
         LIMIT 1;
    END IF;

    -- 3. Evaluate Results based on session existence and expiry
    -- Condition A: No registration session found
    IF v_id IS NULL THEN
        o_success          := FALSE;
        o_http_status      := 404;
        o_message          := 'No registration in progress';
        o_staging_id       := NULL;
        o_current_step     := NULL;
        o_step_name        := NULL;
        o_is_otp_verified  := NULL;
        o_has_basic_info   := FALSE;
        o_metadata         := NULL;
        o_should_start_new := TRUE;

    -- Condition B: Session has expired
    ELSIF CURRENT_TIMESTAMP > v_expires_at THEN
        DELETE FROM "user"."registration_staging" WHERE id = v_id;

        o_success          := FALSE;
        o_http_status      := 400;
        o_message          := 'Registration session expired. Please start again.';
        o_staging_id       := NULL;
        o_current_step     := NULL;
        o_step_name        := NULL;
        o_is_otp_verified  := NULL;
        o_has_basic_info   := FALSE;
        o_metadata         := NULL;
        o_should_start_new := TRUE;

    -- Condition C: Valid session found in progress
    ELSE
        o_success          := TRUE;
        o_http_status      := 200;
        o_message          := 'Registration in progress';
        o_staging_id       := v_id;
        o_current_step     := (v_local_metadata->>'current_step')::INTEGER;
        o_step_name        := v_local_metadata->>'step_name';
        o_is_otp_verified  := v_local_metadata->>'is_otp_verified';
        
        o_has_basic_info   := (
            NULLIF(v_local_metadata->>'first_name', '') IS NOT NULL 
            AND NULLIF(v_local_metadata->>'last_name', '') IS NOT NULL
        );
        
        o_metadata         := v_local_metadata;
        o_should_start_new := FALSE;
    END IF;

END;
$$;


--function verifyLoginOtp

CREATE OR REPLACE PROCEDURE "user"."update_user_after_otp_login"(
    IN  p_user_id          INTEGER,
    IN  p_access_token     TEXT,
    IN  p_token_expiry     VARCHAR(191),
    IN  p_client_secret    TEXT,
    IN  p_secret_expires   TIMESTAMP,
    IN  p_login_region     VARCHAR(191),
    OUT o_rows_updated     INTEGER  -- Output parameter to return the count
)
LANGUAGE plpgsql AS $$
BEGIN
    -- 1. Execute the update statement
    UPDATE "user"."user"
       SET token = p_access_token,
           token_expiry_time = p_token_expiry,
           client_secret = p_client_secret,
           secret_expires = p_secret_expires,
           last_login_region = p_login_region,
           updated_at = CURRENT_TIMESTAMP
     WHERE id = p_user_id
       AND is_deleted = FALSE
       AND is_active = TRUE;

    -- 2. Capture the affected rows count into the OUT parameter
    GET DIAGNOSTICS o_rows_updated = ROW_COUNT;
END;
$$;

--function logout

CREATE OR REPLACE PROCEDURE "user"."logout_user_proc"(
    IN p_user_id INT,
    IN p_refresh_token TEXT,
    INOUT p_result TEXT DEFAULT NULL
)
AS $$
DECLARE
    v_user_exists BOOLEAN;
    v_current_time TIMESTAMP(3) WITHOUT TIME ZONE := NOW()::timestamp(3);
    v_err_msg TEXT;
BEGIN
    -- 1. Verify user context exists inside the system registry
    SELECT EXISTS (
        SELECT 1 FROM "user"."user" WHERE id = p_user_id AND is_deleted = FALSE
    ) INTO v_user_exists;

    IF NOT v_user_exists THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'User context not found.', 'code', 404)::text;
        RETURN;
    END IF;

    -- 2. If a refresh token is supplied, instantly invalidate it inside the token store table
    IF p_refresh_token IS NOT NULL AND TRIM(p_refresh_token) <> '' THEN
        UPDATE "user"."refresh_tokens"
        SET 
            revoked_at = v_current_time,
            revoked_reason = 'user_logout'
        WHERE (id = p_refresh_token OR token_hash = p_refresh_token) -- Matches either absolute ID string or hashed token variant
          AND revoked_at IS NULL;
    END IF;

    -- 3. Clear out security tracking keys and tokens properties inside the "user" row structure
    UPDATE "user"."user"
    SET 
        token = NULL,
        token_expiry_time = NULL,
        client_secret = NULL,
        secret_expires = NULL,
        updated_at = v_current_time
    WHERE id = p_user_id;

    -- 4. Build and package pre-serialized text object confirmation string payload
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'Logged out successfully'
    )::text;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'An unexpected error occurred during logout.', 'details', v_err_msg, 'code', 500)::text;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE "user"."logout_all_devices_proc"(
    IN p_user_id INT,
    IN p_user_uuid TEXT,
    INOUT p_result TEXT DEFAULT NULL
)
AS $$
DECLARE
    v_user_exists BOOLEAN;
    v_current_time TIMESTAMP(3) WITHOUT TIME ZONE := NOW()::timestamp(3);
    v_err_msg TEXT;
BEGIN
    -- 1. Verify user context exists inside the system registry
    SELECT EXISTS (
        SELECT 1 FROM "user"."user" WHERE id = p_user_id AND is_deleted = FALSE
    ) INTO v_user_exists;

    IF NOT v_user_exists THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'User context not found.', 'code', 404)::text;
        RETURN;
    END IF;

    -- 2. Bulk invalidate ALL active token records for this specific user string identification
    UPDATE "user"."refresh_tokens"
    SET 
        revoked_at = v_current_time,
        revoked_reason = 'logout_all_devices'
    WHERE user_id = p_user_uuid
      AND user_type = 'user'
      AND revoked_at IS NULL;

    -- 3. Atomically clear out security tracking columns inside the core "user" table row structure
    UPDATE "user"."user"
    SET 
        token = NULL,
        token_expiry_time = NULL,
        client_secret = NULL,
        secret_expires = NULL,
        updated_at = v_current_time
    WHERE id = p_user_id;

    -- 4. Package pre-serialized text object confirmation string payload
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'All sessions terminated'
    )::text;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'An unexpected error occurred during global logout.', 'details', v_err_msg, 'code', 500)::text;
END;
$$ LANGUAGE plpgsql;

--function - logoutAll

CREATE OR REPLACE PROCEDURE "user"."logout_all_devices_proc"(
    IN p_user_id INT,
    IN p_user_uuid TEXT,
    INOUT p_result TEXT DEFAULT NULL
)
AS $$
DECLARE
    v_user_exists BOOLEAN;
    v_current_time TIMESTAMP(3) WITHOUT TIME ZONE := NOW()::timestamp(3);
    v_err_msg TEXT;
BEGIN
    -- 1. Verify user context exists inside the system registry
    SELECT EXISTS (
        SELECT 1 FROM "user"."user" WHERE id = p_user_id AND is_deleted = FALSE
    ) INTO v_user_exists;

    IF NOT v_user_exists THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'User context not found.', 'code', 404)::text;
        RETURN;
    END IF;

    -- 2. Bulk invalidate ALL active token records for this specific user string identification
    UPDATE "user"."refresh_tokens"
    SET 
        revoked_at = v_current_time,
        revoked_reason = 'logout_all_devices'
    WHERE user_id = p_user_uuid
      AND user_type = 'user'
      AND revoked_at IS NULL;

    -- 3. Atomically clear out security tracking columns inside the core "user" table row structure
    UPDATE "user"."user"
    SET 
        token = NULL,
        token_expiry_time = NULL,
        client_secret = NULL,
        secret_expires = NULL,
        updated_at = v_current_time
    WHERE id = p_user_id;

    -- 4. Package pre-serialized text object confirmation string payload
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'All sessions terminated'
    )::text;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'An unexpected error occurred during global logout.', 'details', v_err_msg, 'code', 500)::text;
END;
$$ LANGUAGE plpgsql;

--function - getProfile

CREATE OR REPLACE PROCEDURE "user"."get_user_profile"(
    p_user_id INT,
    INOUT p_result REFCURSOR DEFAULT 'user_profile_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN p_result FOR
    SELECT
        id,
        "userId", -- Added double quotes to preserve camelCase
        email,
        phone_number,
        phone_prefix,
        first_name,
        last_name,
        username,
        date_of_birth,
        address,
        customer_number,
        role,
        is_phone_verified,
        is_email_verified,
        is_kyc_verified,
        is_bank_kyc_verified,
        gender,
        "profileUrl", -- Added double quotes just in case profileUrl is also camelCase
        is_active,
        created_at,
        updated_at
    FROM "user"."user"
    WHERE id = p_user_id
    LIMIT 1;
END;
$$;

--function - updateProfile

CREATE OR REPLACE PROCEDURE "user"."update_user_profile"(
    p_user_id INT,
    p_date_of_birth TIMESTAMP,
    p_address TEXT,
    p_update_date_of_birth BOOLEAN,
    p_update_address BOOLEAN,
    INOUT p_result REFCURSOR DEFAULT 'updated_profile_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- 1. Perform the conditional update
    -- PostgreSQL uses a CASE WHEN statement instead of MySQL's IF() function
    UPDATE "user"."user"
    SET
        date_of_birth = CASE 
            WHEN p_update_date_of_birth THEN p_date_of_birth 
            ELSE date_of_birth 
        END,
        address = CASE 
            WHEN p_update_address THEN p_address 
            ELSE address 
        END,
        updated_at = CURRENT_TIMESTAMP(3)
    WHERE id = p_user_id;

    -- 2. Open the cursor to return the newly updated user record
    OPEN p_result FOR
    SELECT
        id,
        "userId", -- Double quotes to preserve camelCase syntax
        email,
        phone_number,
        phone_prefix,
        first_name,
        last_name,
        username,
        date_of_birth,
        address,
        customer_number,
        role,
        is_phone_verified,
        is_email_verified,
        is_kyc_verified,
        is_bank_kyc_verified,
        gender,
        is_active,
        created_at,
        updated_at
    FROM "user"."user"
    WHERE id = p_user_id
    LIMIT 1;
END;
$$;

--function - loginWithPassword

CREATE OR REPLACE PROCEDURE "user"."sp_login_with_password"(
    IN p_email VARCHAR(191),
    IN p_phone_number VARCHAR(191),
    IN p_password_hash VARCHAR(191), -- Verified bcrypt hash value passed from Node
    IN p_access_token TEXT,
    IN p_refresh_token TEXT,
    IN p_token_expiry_time TIMESTAMP(3),
    IN p_client_secret TEXT,
    IN p_secret_expires TIMESTAMP(3),
    IN p_user_region VARCHAR(191),
    INOUT p_cursor REFCURSOR DEFAULT 'login_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_user public."user"%ROWTYPE;
BEGIN
    -- 1. Identity Guard Check
    IF (p_email IS NULL OR BTRIM(p_email) = '') AND (p_phone_number IS NULL OR BTRIM(p_phone_number) = '') THEN
        RAISE EXCEPTION 'IdentityViolation: Email or phone number is required.';
    END IF;

    -- 2. Fetch User with row-level transaction blocking
    SELECT * INTO v_user
    FROM "user"."user"
    WHERE (p_email IS NOT NULL AND email = p_email)
       OR (p_phone_number IS NOT NULL AND phone_number = p_phone_number)
    LIMIT 1
    FOR UPDATE;

    -- 3. Verification: Check existence
    IF NOT FOUND THEN
        RAISE EXCEPTION 'NotFoundViolation: Invalid identity records matching given credentials.';
    END IF;

    -- 4. Portal Guard Check: Prevent Admin access via standard login routing paths
    IF EXISTS (
        SELECT 1 FROM "ops"."admin_user" 
        WHERE "userId" = v_user."userId" 
          AND role::text IN ('ADMIN', 'READ_ONLY', 'SUPER_ADMIN') 
          AND is_deleted = FALSE
    ) THEN
        RAISE EXCEPTION 'PortalAccessRestriction: Administrative routing required via /admin/login portal.';
    END IF;

    -- 5. Verification: Password field initialization context check
    IF v_user.password IS NULL OR BTRIM(v_user.password) = '' THEN
        RAISE EXCEPTION 'CredentialStateViolation: Password not set. Please resolve identity profile using OTP.';
    END IF;

    -- 6. String Hash Match Verification
    IF v_user.password <> p_password_hash THEN
        RAISE EXCEPTION 'AuthenticationViolation: Invalid password or identity token.';
    END IF;

    -- 7. Persist Validated Session Token Bounds
    UPDATE "user"."user"
    SET token = p_access_token,
        token_expiry_time = p_token_expiry_time,
        last_login_region = p_user_region
    WHERE id = v_user.id;

    -- 8. Return Response Data Mapping Structure
    OPEN p_cursor FOR
    SELECT 
        u.id,
        u."userId",
        u.email,
        u.phone_number,
        u.first_name,
        u.last_name,
        u.username,
        u.customer_number,
        u.kyc_status,
        p_access_token AS access_token,
        p_refresh_token AS refresh_token,
        p_client_secret AS client_secret
    FROM "user"."user" u
    WHERE u.id = v_user.id;

END;
$$;

--function - setPassword

CREATE OR REPLACE PROCEDURE "user"."set_user_password"(
    p_user_id INT,
    p_hashed_password TEXT,
    INOUT p_affected_rows INT DEFAULT 0
)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE "user"."user"
    SET password = p_hashed_password,
        updated_at = CURRENT_TIMESTAMP(3)
    WHERE id = p_user_id; 

    GET DIAGNOSTICS p_affected_rows = ROW_COUNT;
END;
$$;

--function changePassword

CREATE OR REPLACE PROCEDURE "user"."change_user_password"(
    p_user_id INT,
    p_hashed_new_password TEXT,
    INOUT p_affected_rows INT DEFAULT 
)
LANGUAGE plpgsql
AS $$
BEGIN
        UPDATE "user"."user"
    SET password = p_hashed_new_password,
        updated_at = CURRENT_TIMESTAMP(3)
    WHERE id = p_user_id;

    GET DIAGNOSTICS p_affected_rows = ROW_COUNT;
END;
$$;


--function -checkPasswordStatus

CREATE OR REPLACE PROCEDURE "user"."check_password_status"(
    p_user_id INT,
    INOUT p_has_password BOOLEAN DEFAULT FALSE 
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_password TEXT;
BEGIN

    SELECT password 
    INTO v_password
    FROM "user"."user"
    WHERE id = p_user_id;

    IF v_password IS NOT NULL AND v_password <> '' THEN
        p_has_password := TRUE;
    ELSE
        p_has_password := FALSE;
    END IF;

END;
$$;

--function - adminLogin

CREATE OR REPLACE PROCEDURE "user"."get_dashboard_counts_proc"(
    INOUT p_result JSON DEFAULT NULL
)
AS $$
DECLARE
    v_total_users INT := 0;
    v_total_verified_bank_users INT := 0;
    v_total_risk_profile_users INT := 0;
    v_total_buy_transactions INT := 0;
    v_total_sell_transactions INT := 0;
    v_err_msg TEXT;
BEGIN
    -- 1. Count active users (excluding admins, adjusting table name to "user")
    SELECT COUNT(*) INTO v_total_users 
    FROM "user"."user" 
    WHERE is_active = TRUE;

    -- 2. Count active users with at least one APPROVED, active bank verification
    -- NOTE: Adjust "BankVerification" if your exact table name lowercase/pluralized
    SELECT COUNT(DISTINCT u."userId") INTO v_total_verified_bank_users
    FROM "user"."user" u
    INNER JOIN "BankVerification" bv ON u."userId" = bv.user_id
    WHERE u.is_active = TRUE 
      AND bv.account_status = 'APPROVED' 
      AND bv.is_active = TRUE;

    -- 3. Count users with active risk profiles
    -- NOTE: Adjust "userRiskProfile" to match your exact case-sensitive table name layout
    SELECT COUNT(*) INTO v_total_risk_profile_users 
    FROM "userRiskProfile" 
    WHERE is_active = TRUE;

    -- 4. Count total COMPLETED BUY transactions
    -- NOTE: Adjust "transaction" to match your exact case-sensitive table name layout
    SELECT COUNT(*) INTO v_total_buy_transactions 
    FROM "trade"."transaction" 
    WHERE transaction_type = 'BUY' AND status = 'COMPLETED';

    -- 5. Count total COMPLETED SELL transactions
    SELECT COUNT(*) INTO v_total_sell_transactions 
    FROM "trade"."transaction" 
    WHERE transaction_type = 'SELL' AND status = 'COMPLETED';

    -- 6. Combine all counters into a structured JSON response object payload
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'Dashboard counts fetched successfully',
        'data', JSON_BUILD_OBJECT(
            'total_users', v_total_users,
            'total_verified_bank_users', v_total_verified_bank_users,
            'total_risk_profile_users', v_total_risk_profile_users,
            'total_buy_transactions', v_total_buy_transactions,
            'total_sell_transactions', v_total_sell_transactions,
            'total_transactions', (v_total_buy_transactions + v_total_sell_transactions)
        )
    );

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', v_err_msg, 'code', 500);
END;
$$ LANGUAGE plpgsql;

--function - getDashboardStats

CREATE OR REPLACE PROCEDURE "user"."get_dashboard_stats_proc"(
    INOUT p_result JSON DEFAULT NULL
)
AS $$
DECLARE
    -- User counters
    v_total_users INT := 0;
    v_active_users INT := 0;
    v_inactive_users INT := 0;

    -- Bank verification counters
    v_total_verified_bank_users INT := 0;
    v_pending_bank_verifications INT := 0;
    v_rejected_bank_verifications INT := 0;

    -- Risk profile counters
    v_total_risk_profile_users INT := 0;
    v_conservative_users INT := 0;
    v_balanced_users INT := 0;
    v_growth_users INT := 0;
    v_aggressive_users INT := 0;

    -- Transaction counters & amounts
    v_total_buy_transactions INT := 0;
    v_total_sell_transactions INT := 0;
    v_pending_transactions INT := 0;
    v_failed_transactions INT := 0;
    v_total_buy_amount NUMERIC := 0.00;
    v_total_sell_amount NUMERIC := 0.00;

    v_err_msg TEXT;
BEGIN
    -- 1. Gather User statistics
    SELECT 
        COUNT(*),
        COUNT(*) FILTER (WHERE is_active = TRUE),
        COUNT(*) FILTER (WHERE is_active = FALSE)
    INTO v_total_users, v_active_users, v_inactive_users
    FROM "user"."user"
    WHERE is_deleted = FALSE;

    -- 2. Count active users with at least one APPROVED, active bank verification
    SELECT COUNT(DISTINCT u."userId") INTO v_total_verified_bank_users
    FROM "user"."user" u
    INNER JOIN "kyc"."bank_verification" bv ON u."userId" = bv.user_id
    WHERE u.is_active = TRUE 
      AND u.is_deleted = FALSE
      AND bv.account_status = 'APPROVED' 
      AND bv.is_active = TRUE;

    -- 3. Gather Bank Verification status metrics
    SELECT 
        COUNT(*) FILTER (WHERE account_status = 'PENDING'),
        COUNT(*) FILTER (WHERE account_status = 'REJECTED')
    INTO v_pending_bank_verifications, v_rejected_bank_verifications
    FROM "kyc"."bank_verification"
    WHERE is_active = TRUE;

    -- 4. Gather Risk Profile distribution statistics
    SELECT 
        COUNT(*),
        COUNT(*) FILTER (WHERE risk_level = 'CONSERVATIVE'),
        COUNT(*) FILTER (WHERE risk_level = 'BALANCED'),
        COUNT(*) FILTER (WHERE risk_level = 'GROWTH'),
        COUNT(*) FILTER (WHERE risk_level = 'AGGRESSIVE')
    INTO 
        v_total_risk_profile_users, 
        v_conservative_users, 
        v_balanced_users, 
        v_growth_users, 
        v_aggressive_users
    FROM "catalog"."user_risk_profile"
    WHERE is_active = TRUE;

    -- 5. Gather Transaction lifecycle volume & financial metrics
    SELECT 
        COUNT(*) FILTER (WHERE transaction_type = 'BUY' AND status = 'COMPLETED'),
        COUNT(*) FILTER (WHERE transaction_type = 'SELL' AND status = 'COMPLETED'),
        COUNT(*) FILTER (WHERE status = 'PENDING'),
        COUNT(*) FILTER (WHERE status = 'FAILED'),
        COALESCE(SUM(total_amount) FILTER (WHERE transaction_type = 'BUY' AND status = 'COMPLETED'), 0.00),
        COALESCE(SUM(total_amount) FILTER (WHERE transaction_type = 'SELL' AND status = 'COMPLETED'), 0.00)
    INTO 
        v_total_buy_transactions, 
        v_total_sell_transactions, 
        v_pending_transactions, 
        v_failed_transactions,
        v_total_buy_amount,
        v_total_sell_amount
    FROM "trade"."transaction";

    -- 6. Construct structured nested JSON output payload matching your application logic
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'Dashboard statistics fetched successfully',
        'data', JSON_BUILD_OBJECT(
            'users', JSON_BUILD_OBJECT(
                'total', v_total_users,
                'active', v_active_users,
                'inactive', v_inactive_users
            ),
            'bank_verifications', JSON_BUILD_OBJECT(
                'verified_users', v_total_verified_bank_users,
                'pending', v_pending_bank_verifications,
                'rejected', v_rejected_bank_verifications
            ),
            'risk_profiles', JSON_BUILD_OBJECT(
                'total', v_total_risk_profile_users,
                'without_profile', (v_total_users - v_total_risk_profile_users),
                'conservative', v_conservative_users,
                'balanced', v_balanced_users,
                'growth', v_growth_users,
                'aggressive', v_aggressive_users
            ),
            'transactions', JSON_BUILD_OBJECT(
                'buy', JSON_BUILD_OBJECT(
                    'count', v_total_buy_transactions,
                    'total_amount', TO_CHAR(v_total_buy_amount, 'FM999999999999990.00')
                ),
                'sell', JSON_BUILD_OBJECT(
                    'count', v_total_sell_transactions,
                    'total_amount', TO_CHAR(v_total_sell_amount, 'FM999999999999990.00')
                ),
                'total_count', (v_total_buy_transactions + v_total_sell_transactions),
                'pending', v_pending_transactions,
                'failed', v_failed_transactions
            )
        )
    );

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', v_err_msg, 'code', 500);
END;
$$ LANGUAGE plpgsql;

--function - exportUsersCSV

CREATE OR REPLACE PROCEDURE "user"."export_users_csv_proc"(
    IN p_status TEXT,
    INOUT p_csv_output TEXT DEFAULT NULL
)
AS $$
DECLARE
    v_headers TEXT;
    v_rows TEXT;
    v_err_msg TEXT;
BEGIN
    -- 1. Setup the text CSV layout headers
    v_headers := '"Customer Number","Email","Phone Number","First Name","Last Name","Gender","KYC Verified","Bank KYC Verified","Is Active","Created At"';

    -- 2. Bulk aggregate table rows (Casting gender enum to text explicitly)
    SELECT string_agg(
        '"' || COALESCE("customer_number", '') || '",' ||
        '"' || COALESCE(email, '') || '",' ||
        '"' || COALESCE(phone_number, '') || '",' ||
        '"' || COALESCE(first_name, '') || '",' ||
        '"' || COALESCE(last_name, '') || '",' ||
        '"' || COALESCE(gender::text, '') || '",' || -- Fixed: cast ENUM to text before COALESCE
        '"' || CASE WHEN is_kyc_verified = TRUE THEN 'Yes' ELSE 'No' END || '",' ||
        '"' || CASE WHEN is_bank_kyc_verified = TRUE THEN 'Yes' ELSE 'No' END || '",' ||
        '"' || CASE WHEN is_active = TRUE THEN 'Active' ELSE 'Inactive' END || '",' ||
        '"' || TO_CHAR(created_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') || '"',
        CHR(10) ORDER BY created_at DESC
    )
    INTO v_rows
    FROM "user"."user"
    WHERE is_deleted = FALSE
      AND (
          p_status = 'all' 
          OR (p_status = 'active' AND is_active = TRUE)
          OR (p_status = 'inactive' AND is_active = FALSE)
      );

    -- 3. Tie headers and content rows with a line break character
    p_csv_output := v_headers || CHR(10) || COALESCE(v_rows, '');

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_csv_output := 'ERROR: ' || v_err_msg;
END;
$$ LANGUAGE plpgsql;

--function - exportBankVerificationsCSV

CREATE OR REPLACE PROCEDURE "user"."export_bank_verifications_csv_proc"(
    IN p_status TEXT,
    INOUT p_csv_output TEXT DEFAULT NULL
)
AS $$
DECLARE
    v_headers TEXT;
    v_rows TEXT;
    v_err_msg TEXT;
BEGIN
    -- 1. Setup the structured layout columns headers
    v_headers := '"Customer Number","User Name","Email","Phone","Holder Name","Bank Name","Account Number","Branch Name","IFSC Code","IBAN","Status","Is Primary","Document Type","Created At"';

    -- 2. Execute relational join and aggregate data directly into a CSV text block structure
    SELECT string_agg(
        '"' || COALESCE(bv.customer_number, '') || '",' ||
        '"' || NULLIF(TRIM(CONCAT(u.first_name, ' ', u.last_name)), '') || '",' ||
        '"' || COALESCE(u.email, '') || '",' ||
        '"' || COALESCE(u.phone_number, '') || '",' ||
        '"' || COALESCE(bv.holder_name, '') || '",' ||
        '"' || COALESCE(bv.bank_name, '') || '",' ||
        '"' || COALESCE(bv.account_number, '') || '",' ||
        '"' || COALESCE(bv.branch_name, '') || '",' ||
        '"' || COALESCE(bv.ifsc_code, '') || '",' ||
        '"' || COALESCE(bv.iban, '') || '",' ||
        '"' || COALESCE(bv.account_status::text, '') || '",' || -- Cast account_status enum to text safely
        '"' || CASE WHEN bv.is_primary = TRUE THEN 'Yes' ELSE 'No' END || '",' ||
        '"' || COALESCE(bv.document_type::text, '') || '",' || -- Cast document_type enum to text safely
        '"' || TO_CHAR(bv.created_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') || '"',
        CHR(10) ORDER BY bv.created_at DESC
    )
    INTO v_rows
    FROM "kyc"."bank_verification" bv
    INNER JOIN "user"."user" u ON bv.user_id = u."userId"
    WHERE bv.is_active = TRUE
      AND (p_status = 'all' OR bv.account_status::text = p_status);

    -- 3. Tie header row and aggregate rows data together
    p_csv_output := v_headers || CHR(10) || COALESCE(v_rows, '');

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_csv_output := 'ERROR: ' || v_err_msg;
END;
$$ LANGUAGE plpgsql;

--function - exportTransactionsCSV

CREATE OR REPLACE PROCEDURE "user"."get_user_sessions_proc"(
    IN p_user_id VARCHAR,
    IN p_limit INT,
    IN p_offset INT,
    IN p_include_expired BOOLEAN,
    INOUT p_result JSON DEFAULT NULL
)
AS $$
DECLARE
    v_user_exists BOOLEAN;
    v_total_sessions INT;
    v_active_sessions INT;
    v_sessions_json JSON;
    v_current_time TIMESTAMP := NOW();
    v_err_msg TEXT;
    v_err_detail TEXT;
BEGIN
    -- 1. Check if user exists (Using exact "user" table name)
    SELECT EXISTS (
        SELECT 1 FROM "user"."user" 
        WHERE "userId" = p_user_id AND "is_deleted" = FALSE
    ) INTO v_user_exists;

    IF NOT v_user_exists THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'User not found', 'code', 404);
        RETURN;
    END IF;

    -- 2. Count total matched sessions (Using exact refresh_tokens table name)
    SELECT COUNT(*) INTO v_total_sessions
    FROM "user"."refresh_tokens"
    WHERE user_id = p_user_id 
      AND user_type = 'user'
      AND (p_include_expired = TRUE OR expires_at >= v_current_time);

    -- 3. Count active sessions
    SELECT COUNT(*) INTO v_active_sessions
    FROM "user"."refresh_tokens"
    WHERE user_id = p_user_id 
      AND user_type = 'user'
      AND is_used = FALSE 
      AND revoked_at IS NULL 
      AND expires_at >= v_current_time;

    -- 4. Get paginated array records
    SELECT COALESCE(JSON_AGG(t), '[]'::JSON) INTO v_sessions_json
    FROM (
        SELECT 
            id,
            family_id AS "familyId",
            created_at AS "createdAt",
            expires_at AS "expiresAt",
            revoked_at AS "revokedAt",
            revoked_reason AS "revokedReason",
            is_used AS "isUsed",
            device_info AS "deviceInfo"
        FROM "user"."refresh_tokens"
        WHERE user_id = p_user_id 
          AND user_type = 'user'
          AND (p_include_expired = TRUE OR expires_at >= v_current_time)
        ORDER BY created_at DESC
        LIMIT LEAST(p_limit, 200)
        OFFSET GREATEST(p_offset, 0)
    ) t;

    -- 5. Build final result payload
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'data', JSON_BUILD_OBJECT(
            'sessions', v_sessions_json,
            'totalSessions', v_total_sessions,
            'activeSessionCount', v_active_sessions
        )
    );

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_detail = PG_EXCEPTION_DETAIL;
    RAISE NOTICE 'CRITICAL INTERNAL DB ERROR: % | DETAIL: %', v_err_msg, v_err_detail;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', v_err_msg, 'code', 500);
END;
$$ LANGUAGE plpgsql;


--function - forceLogoutUser

CREATE OR REPLACE PROCEDURE "user"."get_active_session_users_proc"(
    INOUT p_result JSON DEFAULT NULL
)
AS $$
DECLARE
    v_users_json JSON;
    v_total_users INT;
    v_current_time TIMESTAMP(3) WITHOUT TIME ZONE := NOW()::timestamp(3);
    v_err_msg TEXT;
BEGIN
    -- 1. Gather all active users, join profile data, and count sessions in one query
    SELECT 
        COALESCE(JSON_AGG(t), '[]'::JSON),
        COUNT(*)
    INTO 
        v_users_json,
        v_total_users
    FROM (
        SELECT 
            u."userId" AS "id",
            NULLIF(TRIM(CONCAT(u.first_name, ' ', u.last_name)), '') AS "name",
            COALESCE(u.email, '—') AS "email",
            COALESCE(u.phone_number, '—') AS "phone",
            COUNT(rt.id)::INT AS "activeSessionCount"
        FROM "user"."refresh_tokens" rt
        INNER JOIN "user"."user" u ON rt.user_id = u."userId"
        WHERE rt.user_type = 'user'
          AND rt.is_used = FALSE
          AND rt.revoked_at IS NULL
          AND rt.expires_at >= v_current_time
          AND u.is_deleted = FALSE
        GROUP BY u."userId", u.first_name, u.last_name, u.email, u.phone_number
        ORDER BY "activeSessionCount" DESC  -- Sort by highest active sessions first
    ) t;
SELECT * FROM "user"."refresh_tokens";
-- 2. Build the structured final success payload response object
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'data', JSON_BUILD_OBJECT(
            'users', v_users_json,
            'total', COALESCE(v_total_users, 0)
        )
    );

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', v_err_msg, 'code', 500);
END;
$$ LANGUAGE plpgsql;

--function - revokeUserSession

CREATE OR REPLACE PROCEDURE "user"."revoke_user_session_proc"(
    IN p_user_id TEXT,
    IN p_family_id TEXT,
    IN p_admin_email TEXT,
    IN p_admin_name TEXT,
    IN p_ip_address TEXT,
    IN p_browser TEXT,
    IN p_metadata JSONB,
    INOUT p_result JSON DEFAULT NULL
)
AS $$
DECLARE
    v_user_exists BOOLEAN;
    v_user_email VARCHAR(191);
    v_user_first_name VARCHAR(191);
    v_user_last_name VARCHAR(191);
    v_session_device_info JSONB;
    v_active_count INT;
    v_full_metadata JSONB;
    v_next_log_id INT;
    v_current_time TIMESTAMP(3) WITHOUT TIME ZONE := NOW()::timestamp(3);
    v_err_msg TEXT;
BEGIN
    SELECT 
        TRUE, email, first_name, last_name 
    INTO 
        v_user_exists, v_user_email, v_user_first_name, v_user_last_name
    FROM "user"."user" 
    WHERE "userId" = p_user_id AND "is_deleted" = FALSE;

    IF NOT v_user_exists OR v_user_exists IS NULL THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'User not found', 'code', 404);
        RETURN;
    END IF;

    SELECT device_info INTO v_session_device_info
    FROM "user"."refresh_tokens"
    WHERE family_id = p_family_id AND user_id = p_user_id AND user_type = 'user'
    LIMIT 1;

    IF NOT FOUND THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'Session not found for this user', 'code', 404);
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_active_count
    FROM "user"."refresh_tokens"
    WHERE family_id = p_family_id AND revoked_at IS NULL;

    IF v_active_count = 0 THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'Session is already revoked', 'code', 400);
        RETURN;
    END IF;

    UPDATE "user"."refresh_tokens"
    SET 
        revoked_at = v_current_time,
        revoked_reason = 'force_logout_single'
    WHERE family_id = p_family_id 
      AND user_id = p_user_id 
      AND revoked_at IS NULL;

    v_full_metadata := p_metadata || JSONB_BUILD_OBJECT(
        'targetUserId', p_user_id,
        'targetEmail', COALESCE(v_user_email, NULL),
        'targetName', NULLIF(TRIM(CONCAT(v_user_first_name, ' ', v_user_last_name)), ''),
        'familyId', p_family_id,
        'deviceIp', COALESCE(v_session_device_info->>'ip', NULL),
        'devicePlatform', COALESCE(v_session_device_info->>'platform', NULL),
        'terminatedAt', TO_CHAR(v_current_time, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    );

    SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_log_id FROM "ops"."audit_logs";

    INSERT INTO "ops"."audit_logs" (id,module, "actionType","entityType", "entityId","statusBefore","statusAfter","actionReason","adminEmail","adminName","ipAddress",browser,success,metadata,"createdAt" ) 
	VALUES (v_next_log_id,'Sessions','Single Device Logout','User Session',p_user_id,'active','terminated','Admin terminated a specific device session',p_admin_email,p_admin_name,p_ip_address,p_browser,TRUE,v_full_metadata,v_current_time);

    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'Device session terminated successfully',
        'familyId', p_family_id
    );

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', v_err_msg, 'code', 500);
END;
$$ LANGUAGE plpgsql;

--function - createAdminUser

CREATE OR REPLACE PROCEDURE "user"."verify_user_mpin_sp"(
    IN    p_user_id     VARCHAR(191),
    INOUT p_success     BOOLEAN DEFAULT FALSE,
    INOUT p_message     TEXT DEFAULT NULL,
    INOUT p_status_code INT DEFAULT 200,
    INOUT p_mpin_hash   VARCHAR(255) DEFAULT NULL
) AS $$
DECLARE
    v_user_exists BOOLEAN;
    v_mpin_hash   VARCHAR(255);
BEGIN
    -- 1. Structural Validation
    IF p_user_id IS NULL OR p_user_id = '' THEN
        p_success     := FALSE;
        p_message     := 'User ID is required';
        p_status_code := 400;
        p_mpin_hash   := NULL;
        RETURN;
    END IF;

    -- 2. Check if the user exists in the core "user" table
    SELECT EXISTS(
        SELECT 1 FROM "user"."user" WHERE "userId" = p_user_id AND is_deleted = FALSE
    ) INTO v_user_exists;

    -- 3. Case 1: Handle user not found state
    IF NOT v_user_exists THEN
        p_success     := FALSE;
        p_message     := 'User not found';
        p_status_code := 404;
        p_mpin_hash   := NULL;
        RETURN;
    END IF;

    -- 4. Lookup the assigned mpinhash from the row record
    SELECT mpinhash 
    INTO v_mpin_hash
    FROM "user"."user"
    WHERE "userId" = p_user_id AND is_deleted = FALSE;

    -- 5. Case 2: Handle unconfigured/unset MPIN state
    IF v_mpin_hash IS NULL OR v_mpin_hash = '' THEN
        p_success     := FALSE;
        p_message     := 'MPIN is not set for this account';
        p_status_code := 400;
        p_mpin_hash   := NULL;
        RETURN;
    END IF;

    -- 6. Success Case: Pass the hash back to the Node.js application layer
    p_success     := TRUE;
    p_message     := 'User MPIN payload fetched successfully';
    p_status_code := 200;
    p_mpin_hash   := v_mpin_hash;

EXCEPTION
    WHEN OTHERS THEN
        p_success     := FALSE;
        p_message     := 'Database Exception Error: ' || SQLERRM;
        p_status_code := 500;
        p_mpin_hash   := NULL;
END;
$$ LANGUAGE plpgsql;

--function - ForgotMpinSendOtp

CREATE OR REPLACE PROCEDURE "user"."prepare_forgot_mpin_otp"(
    IN  p_email TEXT,
    IN  p_otp_hash TEXT,
    IN  p_otp_expires TIMESTAMP,
    OUT p_status TEXT,
    OUT p_user_id INTEGER,
    OUT p_registered_email TEXT,
    OUT p_first_name TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_mpin_hash TEXT;
BEGIN
    p_user_id := NULL;
    p_registered_email := NULL;
    p_first_name := NULL;

    SELECT u.id, u.email, u.first_name, u.mpinhash
    INTO p_user_id, p_registered_email, p_first_name, v_mpin_hash
    FROM "user"."user" AS u
    WHERE u.email = p_email
      AND u.is_deleted = FALSE
    LIMIT 1;

    IF NOT FOUND THEN
        p_status := 'not_found';
        RETURN;
    END IF;

    IF v_mpin_hash IS NULL THEN
        p_status := 'mpin_not_set';
        RETURN;
    END IF;

    UPDATE "user"."user"
    SET mpin_otp_hash = p_otp_hash,
        mpin_otp_expires = p_otp_expires,
        mpin_reset_token = NULL,
        mpin_reset_token_expires = NULL
    WHERE id = p_user_id;

    p_status := 'otp_prepared';
END;
$$;

--function - ChangeMpin

CREATE OR REPLACE PROCEDURE "user"."change_mpin"(
    IN p_user_id TEXT,
    IN p_hashed_new_mpin TEXT,
    OUT p_status TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    SELECT id
    INTO v_user_id
    FROM "user"."user"
    WHERE "userId" = p_user_id
    LIMIT 1;

    IF NOT FOUND THEN
        p_status := 'user_not_found';
        RETURN;
    END IF;

    UPDATE "user"."user"
    SET mpinhash = p_hashed_new_mpin
    WHERE id = v_user_id;

    p_status := 'mpin_changed';
END;
$$;

--function - ResetMpin

CREATE OR REPLACE PROCEDURE "user"."update_mpin"(
    p_email TEXT,
    p_hashed_mpin TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE "user"."user"
    SET mpinhash = p_hashed_mpin,
        mpin_reset_token = NULL,
        mpin_reset_token_expires = NULL
    WHERE email = p_email
      AND is_deleted = FALSE;
END;
$$;

--function - ForgotMpinVerifyOtp

CREATE OR REPLACE PROCEDURE "user"."verify_forgot_mpin_otp"(
    IN  p_email TEXT,
    IN  p_otp_hash TEXT,
    IN  p_reset_token TEXT,
    IN  p_reset_token_expires TIMESTAMP,
    OUT p_status TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id INTEGER;
    v_saved_otp_hash TEXT;
    v_otp_expires TIMESTAMP;
BEGIN
    SELECT id, mpin_otp_hash, mpin_otp_expires
    INTO v_user_id, v_saved_otp_hash, v_otp_expires
    FROM "user"."user"
    WHERE email = p_email
      AND is_deleted = FALSE
    LIMIT 1;

    IF NOT FOUND OR v_saved_otp_hash IS NULL THEN
        p_status := 'no_otp';
        RETURN;
    END IF;

    IF v_otp_expires IS NULL OR CURRENT_TIMESTAMP > v_otp_expires THEN
        UPDATE "user"."user"
        SET mpin_otp_hash = NULL,
            mpin_otp_expires = NULL
        WHERE id = v_user_id;

        p_status := 'expired';
        RETURN;
    END IF;

    IF v_saved_otp_hash <> p_otp_hash THEN
        p_status := 'invalid_otp';
        RETURN;
    END IF;

    UPDATE "user"."user"
    SET mpin_otp_hash = NULL,
        mpin_otp_expires = NULL,
        mpin_reset_token = p_reset_token,
        mpin_reset_token_expires = p_reset_token_expires
    WHERE id = v_user_id;

    p_status := 'verified';
END;
$$;

--function - getAllUsers

CREATE OR REPLACE PROCEDURE "user"."get_all_users_admin_proc"(
    IN p_page INT,
    IN p_limit INT,
    IN p_search TEXT,
    IN p_kyc_status TEXT,
    IN p_role TEXT,
    IN p_is_active BOOLEAN,
    IN p_is_kyc_verified BOOLEAN,
    IN p_is_email_verified BOOLEAN,
    IN p_is_phone_verified BOOLEAN,
    IN p_is_risk_verified BOOLEAN,
    IN p_is_bank_kyc_verified BOOLEAN,
    IN p_is_export BOOLEAN,
    INOUT p_web_result JSON DEFAULT NULL,
    INOUT p_csv_result TEXT DEFAULT NULL
)
AS $$
DECLARE
    v_skip INT;
    v_total_filtered INT := 0;
    v_total_users INT := 0;
    v_active_count INT := 0;
    v_inactive_count INT := 0;
    v_users_json JSON;
    v_csv_rows TEXT;
    v_csv_headers TEXT; -- Aligned syntax naming variable configuration holder
    v_err_msg TEXT;
BEGIN
    -- 1. Initialize safe pagination parameters boundaries
    v_skip := (GREATEST(p_page, 1) - 1) * p_limit;

    -- 2. Build and populate summary stats counters globally (excluding soft-deleted rows)
    SELECT 
        COUNT(*),
        COUNT(*) FILTER (WHERE is_active = TRUE),
        COUNT(*) FILTER (WHERE is_active = FALSE)
    INTO v_total_users, v_active_count, v_inactive_count
    FROM "user"."user"
    WHERE is_deleted = FALSE;

    -- 3. Branching Pathway: Export CSV Processing vs Web Pagination Lookups
    IF p_is_export = TRUE THEN
        -- Standard formatting headers for spreadsheet software compliance mapping
        v_csv_headers := '"ID","User ID","Customer Number","Email","First Name","Last Name","Gender","Phone Prefix","Phone Number","Date of Birth","Address","Platform","Role","KYC Status","Bank KYC Status","Is Active","Email Verified","Phone Verified","KYC Verified","Bank KYC Verified","Risk Verified","Created At","Updated At"';

        -- Aggregate matching dataset directly into raw string arrays at database memory layer
        SELECT string_agg(
            '"' || REPLACE(COALESCE(id::text, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE("userId", ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(customer_number, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(email, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(first_name, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(last_name, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(gender::text, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(phone_prefix, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(phone_number, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(date_of_birth::text, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(address, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(platform, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(role, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(kyc_status, ''), '"', '""') || '",' ||
            '"' || REPLACE(COALESCE(bankkyc_status, ''), '"', '""') || '",' ||
            '"' || CASE WHEN is_active = TRUE THEN 'Yes' ELSE 'No' END || '",' ||
            '"' || CASE WHEN is_email_verified = TRUE THEN 'Yes' ELSE 'No' END || '",' ||
            '"' || CASE WHEN is_phone_verified = TRUE THEN 'Yes' ELSE 'No' END || '",' ||
            '"' || CASE WHEN is_kyc_verified = TRUE THEN 'Yes' ELSE 'No' END || '",' ||
            '"' || CASE WHEN is_bank_kyc_verified = TRUE THEN 'Yes' ELSE 'No' END || '",' ||
            '"' || CASE WHEN is_risk_verified = TRUE THEN 'Yes' ELSE 'No' END || '",' ||
            '"' || TO_CHAR(created_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') || '精度",' ||
            '"' || TO_CHAR(updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') || '"',
            CHR(10) ORDER BY created_at DESC
        )
        INTO v_csv_rows
        FROM "user"."user"
        WHERE is_deleted = FALSE
          AND (p_kyc_status IS NULL OR kyc_status = p_kyc_status)
          AND (p_role IS NULL OR role = p_role)
          AND (p_is_active IS NULL OR is_active = p_is_active)
          AND (p_is_kyc_verified IS NULL OR is_kyc_verified = p_is_kyc_verified)
          AND (p_is_email_verified IS NULL OR is_email_verified = p_is_email_verified)
          AND (p_is_phone_verified IS NULL OR is_phone_verified = p_is_phone_verified)
          AND (p_is_risk_verified IS NULL OR is_risk_verified = p_is_risk_verified)
          AND (p_is_bank_kyc_verified IS NULL OR is_bank_kyc_verified = p_is_bank_kyc_verified)
          AND (p_search IS NULL OR (
                email ILIKE '%' || p_search || '%' OR 
                first_name ILIKE '%' || p_search || '%' OR 
                last_name ILIKE '%' || p_search || '%' OR 
                phone_number ILIKE '%' || p_search || '%' OR 
                customer_number ILIKE '%' || p_search || '%'
          ));

        p_csv_result := v_csv_headers || CHR(10) || COALESCE(v_csv_rows, '');
        p_web_result := NULL;

    ELSE
        -- Calculate Total filtered matching row count for dynamic pagination tracking summaries
        SELECT COUNT(*) INTO v_total_filtered
        FROM "user"."user"
        WHERE is_deleted = FALSE
          AND (p_kyc_status IS NULL OR kyc_status = p_kyc_status)
          AND (p_role IS NULL OR role = p_role)
          AND (p_is_active IS NULL OR is_active = p_is_active)
          AND (p_is_kyc_verified IS NULL OR is_kyc_verified = p_is_kyc_verified)
          AND (p_is_email_verified IS NULL OR is_email_verified = p_is_email_verified)
          AND (p_is_phone_verified IS NULL OR is_phone_verified = p_is_phone_verified)
          AND (p_is_risk_verified IS NULL OR is_risk_verified = p_is_risk_verified)
          AND (p_is_bank_kyc_verified IS NULL OR is_bank_kyc_verified = p_is_bank_kyc_verified)
          AND (p_search IS NULL OR (
                email ILIKE '%' || p_search || '%' OR 
                first_name ILIKE '%' || p_search || '%' OR 
                last_name ILIKE '%' || p_search || '%' OR 
                phone_number ILIKE '%' || p_search || '%' OR 
                customer_number ILIKE '%' || p_search || '%'
          ));

        -- Fetch precise data metrics matching current index steps
        SELECT COALESCE(JSON_AGG(sub), '[]'::JSON) INTO v_users_json
        FROM (
            SELECT 
                id, "userId", email, first_name, last_name, gender::text,
                phone_number, phone_prefix, "profileUrl", address, kyc_status,
                bankkyc_status, currency_pref, date_of_birth, customer_number,
                platform, role, is_phone_verified, is_email_verified,
                is_kyc_verified, is_bank_kyc_verified, is_risk_verified,
                is_active, created_at, updated_at
            FROM "user"."user"
            WHERE is_deleted = FALSE
              AND (p_kyc_status IS NULL OR kyc_status = p_kyc_status)
              AND (p_role IS NULL OR role = p_role)
              AND (p_is_active IS NULL OR is_active = p_is_active)
              AND (p_is_kyc_verified IS NULL OR is_kyc_verified = p_is_kyc_verified)
              AND (p_is_email_verified IS NULL OR is_email_verified = p_is_email_verified)
              AND (p_is_phone_verified IS NULL OR is_phone_verified = p_is_phone_verified)
              AND (p_is_risk_verified IS NULL OR is_risk_verified = p_is_risk_verified)
              AND (p_is_bank_kyc_verified IS NULL OR is_bank_kyc_verified = p_is_bank_kyc_verified)
              AND (p_search IS NULL OR (
                    email ILIKE '%' || p_search || '%' OR 
                    first_name ILIKE '%' || p_search || '%' OR 
                    last_name ILIKE '%' || p_search || '%' OR 
                    phone_number ILIKE '%' || p_search || '%' OR 
                    customer_number ILIKE '%' || p_search || '%'
              ))
            ORDER BY created_at DESC
            LIMIT p_limit OFFSET v_skip
        ) sub;

        -- Format final application framework JSON package layout
        p_web_result := JSON_BUILD_OBJECT(
            'success', TRUE,
            'data', JSON_BUILD_OBJECT(
                'users', v_users_json,
                'totalCount', v_total_filtered,
                'counts', JSON_BUILD_OBJECT(
                    'ALL', v_total_users,
                    'ACTIVE', v_active_count,
                    'INACTIVE', v_inactive_count
                )
            )
        );
        p_csv_result := NULL;
    END IF;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_web_result := JSON_BUILD_OBJECT('success', FALSE, 'error', v_err_msg);
    p_csv_result := 'ERROR: ' || v_err_msg;
END;
$$ LANGUAGE plpgsql;


--function - toggleUserActive

CREATE OR REPLACE PROCEDURE "user"."toggle_user_active_proc"(
	IN p_search_id text,
	INOUT p_result text DEFAULT NULL::text)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_user_id_int INT;
    v_target_id INT;
    v_current_active BOOLEAN;
    v_new_active BOOLEAN;
    v_updated_user JSON;
    v_current_time TIMESTAMP(3) WITHOUT TIME ZONE := NOW()::timestamp(3);
    v_err_msg TEXT;
BEGIN
    -- 1. Safely handle integer type casting for sequential ID checks
    BEGIN
        v_user_id_int := p_search_id::INT;
    EXCEPTION WHEN OTHERS THEN
        v_user_id_int := 0;
    END;

    -- 2. Find the user across UUID string, Integer ID, or Customer Number layouts
    SELECT id, is_active 
    INTO v_target_id, v_current_active
    FROM "user"."user"
    WHERE is_deleted = FALSE
      AND (
          "userId" = p_search_id 
          OR customer_number = p_search_id 
          OR (v_user_id_int > 0 AND id = v_user_id_int)
      )
    LIMIT 1;

    -- Return 404 if the user cannot be located
    IF v_target_id IS NULL THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'User not found', 'code', 404)::text;
        RETURN;
    END IF;

    -- 3. Toggle the boolean account state value logic
    v_new_active := NOT v_current_active;

    -- 4. Execute atomic account update modifications
    UPDATE "user"."user"
    SET 
        is_active = v_new_active,
        updated_at = v_current_time
    WHERE id = v_target_id;

    -- 5. CRITICAL SECURITY: If deactivated, instantly kill all active devices sessions
    IF v_new_active = FALSE THEN
        UPDATE "user"."refresh_tokens"
        SET 
            revoked_at = v_current_time,
            revoked_reason = 'User account deactivated by administrator'
        WHERE user_id = (SELECT "userId" FROM "user"."user" WHERE id = v_target_id)
          AND user_type = 'user'
          AND revoked_at IS NULL;
    END IF;

    -- 6. Collect final sanitized response details (omitting secrets)
    SELECT JSON_BUILD_OBJECT(
        'id', id,
        'userId', "userId",
        'email', COALESCE(email, ''),
        'first_name', COALESCE(first_name, ''),
        'last_name', COALESCE(last_name, ''),
        'customer_number', COALESCE(customer_number, ''),
        'is_active', is_active
    ) INTO v_updated_user
    FROM "user"."user"
    WHERE id = v_target_id;

    -- 7. Return string payload
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'User ' || CASE WHEN v_new_active = TRUE THEN 'activated' ELSE 'deactivated' END || ' successfully',
        'data', v_updated_user
    )::text;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', v_err_msg, 'code', 500)::text;
END;
$$;

--function - getUserById

CREATE OR REPLACE PROCEDURE "user"."get_user_by_id_proc"(
    IN p_search_id TEXT,
    INOUT p_result TEXT DEFAULT NULL
)
AS $$
DECLARE
    v_user_id_int INT;
    v_target_id INT;
    v_user_json JSON;
    v_err_msg TEXT;
BEGIN
    -- 1. Safely handle integer type casting for sequential structural ID checks
    BEGIN
        v_user_id_int := p_search_id::INT;
    EXCEPTION WHEN OTHERS THEN
        v_user_id_int := 0;
    END;

    -- 2. Locate the user cross-referencing UUID, custom number, or internal sequential keys
    SELECT id 
    INTO v_target_id
    FROM "user"."user"
    WHERE is_deleted = FALSE
      AND (
          "userId" = p_search_id 
          OR customer_number = p_search_id 
          OR (v_user_id_int > 0 AND id = v_user_id_int)
      )
    LIMIT 1;

    -- Return clean operational 404 block if entity cannot be found
    IF v_target_id IS NULL THEN
        p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', 'User not found', 'code', 404)::text;
        RETURN;
    END IF;

    -- 3. Fetch all designated layout fields while strictly avoiding security leaks (passwords, tokens)
    SELECT JSON_BUILD_OBJECT(
        'id', id,
        'userId', "userId",
        'email', COALESCE(email, ''),
        'first_name', COALESCE(first_name, ''),
        'last_name', COALESCE(last_name, ''),
        'gender', COALESCE(gender::text, ''), -- Handle strict casting for enum validation values
        'phone_number', COALESCE(phone_number, ''),
        'phone_prefix', COALESCE(phone_prefix, ''),
        'profileUrl', COALESCE("profileUrl", ''),
        'address', COALESCE(address, ''),
        'kyc_status', COALESCE(kyc_status, ''),
        'bankkyc_status', COALESCE(bankkyc_status, ''),
        'currency_pref', COALESCE(currency_pref, ''),
        'date_of_birth', COALESCE(date_of_birth::text, ''),
        'customer_number', COALESCE(customer_number, ''),
        'platform', COALESCE(platform, ''),
        'role', COALESCE(role, ''),
        'is_phone_verified', is_phone_verified,
        'is_email_verified', is_email_verified,
        'is_kyc_verified', is_kyc_verified,
        'is_bank_kyc_verified', is_bank_kyc_verified,
        'is_risk_verified', is_risk_verified,
        'is_active', is_active,
        'is_tnc_checked', is_tnc_checked,
        'referral', COALESCE(referral, ''),
        'created_at', TO_CHAR(created_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
        'updated_at', TO_CHAR(updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    ) INTO v_user_json
    FROM "user"."user"
    WHERE id = v_target_id;

    -- 4. Package pre-serialized text object string value payload
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'data', v_user_json
    )::text;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', v_err_msg, 'code', 500)::text;
END;
$$ LANGUAGE plpgsql;


--function - getRiskProfileQuestions,

CREATE OR REPLACE PROCEDURE "user"."sp_upload_profile_image"(
    IN p_user_id INTEGER,
    IN p_new_profile_url TEXT,
    INOUT p_old_image_cursor REFCURSOR DEFAULT 'old_image_cursor',
    INOUT p_updated_user_cursor REFCURSOR DEFAULT 'updated_user_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_profile_url TEXT;
BEGIN
    -- 1. Fail fast if inputs are missing
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'ValidationViolation: User ID is required.';
    END IF;
    IF p_new_profile_url IS NULL OR BTRIM(p_new_profile_url) = '' THEN
        RAISE EXCEPTION 'ValidationViolation: New profile URL is required.';
    END IF;

    -- 2. Fetch current profile image path and apply an atomic row-level write lock
    SELECT "profileUrl" INTO v_old_profile_url
    FROM "user"."user"
    WHERE id = p_user_id
    FOR UPDATE;

    -- 3. Verification: Ensure user exists
    IF NOT FOUND THEN
        RAISE EXCEPTION 'NotFoundViolation: User record does not exist.';
    END IF;

    -- 4. Open first cursor to return old file path data back to the application layer
    OPEN p_old_image_cursor FOR
    SELECT v_old_profile_url AS old_profile_url;

    -- 5. Perform atomic data mutation updating the target record profile URL
    UPDATE "user"."user"
    SET "profileUrl" = p_new_profile_url
    WHERE id = p_user_id;

    -- 6. Open second cursor returning newly mutated tracking records
    OPEN p_updated_user_cursor FOR
    SELECT 
        id,
        "userId",
        email,
        first_name,
        last_name,
        "profileUrl"
    FROM "user"."user"
    WHERE id = p_user_id;

END;
$$;

--function - deleteProfileImage

CREATE OR REPLACE PROCEDURE "user"."sp_delete_profile_image"(
    IN p_user_id INTEGER,
    INOUT p_deleted_image_cursor REFCURSOR DEFAULT 'deleted_image_cursor',
    INOUT p_updated_user_cursor REFCURSOR DEFAULT 'updated_user_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_profile_url TEXT;
BEGIN
    -- 1. Fail fast if identity inputs are missing
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'ValidationViolation: User ID is required.';
    END IF;

    -- 2. Fetch current profile image path with row-level update locking context
    SELECT "profileUrl" INTO v_current_profile_url
    FROM "user"."user"
    WHERE id = p_user_id
    FOR UPDATE;

    -- 3. Verification: Ensure user exists
    IF NOT FOUND THEN
        RAISE EXCEPTION 'NotFoundViolation: User record does not exist.';
    END IF;

    -- 4. Verification: Return a specific application error if no image is set
    IF v_current_profile_url IS NULL OR BTRIM(v_current_profile_url) = '' THEN
        RAISE EXCEPTION 'NoImageAssetViolation: No profile image found to delete.';
    END IF;

    -- 5. Open cursor to stream file target paths back to application thread layer
    OPEN p_deleted_image_cursor FOR
    SELECT v_current_profile_url AS profile_url_to_delete;

    -- 6. Execute atomic update mutating target profile mapping down to NULL
    UPDATE "user"."user"
    SET "profileUrl" = NULL
    WHERE id = p_user_id;

    -- 7. Open summary cursor containing updated configuration profiles
    OPEN p_updated_user_cursor FOR
    SELECT 
        id,
        "userId",
        email,
        first_name,
        last_name,
        "profileUrl"
    FROM "user"."user"
    WHERE id = p_user_id;

END;
$$;



--function - getBankVerificationStatuses

CREATE OR REPLACE PROCEDURE "user"."sp_get_all_bank_verifications"(
    IN p_page INTEGER DEFAULT 1,
    IN p_limit INTEGER DEFAULT 10,
    IN p_search TEXT DEFAULT NULL,
    IN p_account_status TEXT DEFAULT NULL,
    IN p_bank_name TEXT DEFAULT NULL,
    IN p_is_primary BOOLEAN DEFAULT NULL,
    IN p_customer_number VARCHAR(191) DEFAULT NULL,
    IN p_export BOOLEAN DEFAULT FALSE,
    INOUT p_cursor REFCURSOR DEFAULT 'result_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_page INTEGER := GREATEST(COALESCE(p_page, 1), 1);
    v_limit INTEGER := GREATEST(COALESCE(p_limit, 10), 1);
    v_offset INTEGER;
BEGIN
    v_offset := (v_page - 1) * v_limit;

    IF p_account_status IS NOT NULL
       AND p_account_status NOT IN
           ('PENDING', 'APPROVED', 'REJECTED', 'ON_HOLD') THEN
        RAISE EXCEPTION
            'Invalid account status. Must be PENDING, APPROVED, REJECTED or ON_HOLD';
    END IF;

    OPEN p_cursor FOR
    WITH filtered AS
    (
        SELECT
            bv.id,
            bv.customer_number,
            bv.holder_name,
            bv.account_number,
            bv.bank_name,
            bv.branch_name,
            bv.ifsc_code,
            bv.iban,
            bv.document_type,
            bv.document_url,
            bv.account_status,
            bv.is_primary,
            bv.is_active,
            bv."createdAt",
            bv."updatedAt",
            bv.onhold_template_id,

            u."userId",
            u.first_name,
            u.last_name,
            u.email,
            u.phone_number,

            rt.id AS onhold_reason_id,
            rt.reason AS onhold_reason_name,

            ROW_NUMBER() OVER (
                PARTITION BY bv.customer_number
                ORDER BY bv."createdAt" DESC, bv.id DESC
            ) AS latest_account_rank

        FROM "kyc"."bank_verification" bv

        LEFT JOIN "user"."user" u
            ON u.customer_number = bv.customer_number

        LEFT JOIN "catalog"."reason_templates" rt
            ON rt.id = bv.onhold_template_id

        WHERE bv.is_active = TRUE

          AND (
              p_customer_number IS NULL
              OR bv.customer_number = p_customer_number
          )

          AND (
              p_bank_name IS NULL
              OR bv.bank_name ILIKE '%' || p_bank_name || '%'
          )

          AND (
              p_is_primary IS NULL
              OR bv.is_primary = p_is_primary
          )

          AND (
              p_search IS NULL
              OR BTRIM(p_search) = ''
              OR bv.holder_name ILIKE '%' || p_search || '%'
              OR bv.account_number ILIKE '%' || p_search || '%'
              OR bv.iban ILIKE '%' || p_search || '%'
              OR bv.bank_name ILIKE '%' || p_search || '%'
              OR bv.customer_number ILIKE '%' || p_search || '%'
              OR u.email ILIKE '%' || p_search || '%'
              OR u.first_name ILIKE '%' || p_search || '%'
              OR u.last_name ILIKE '%' || p_search || '%'
              OR u.phone_number ILIKE '%' || p_search || '%'
          )
    ),

    latest AS
    (
        SELECT DISTINCT ON (customer_number)
            customer_number,
            account_status AS latest_account_status
        FROM filtered
        ORDER BY customer_number, "createdAt" DESC, id DESC
    ),

    customer_counts AS
    (
        SELECT
            f.customer_number,

            COUNT(*) AS total_accounts,

            MAX(
                CASE
                    WHEN f.is_primary THEN f.id
                    ELSE NULL
                END
            ) AS primary_account,

            COUNT(*) FILTER (
                WHERE f.account_status = 'APPROVED'
            ) AS approved_count,

            COUNT(*) FILTER (
                WHERE f.account_status = 'PENDING'
            ) AS pending_count,

            COUNT(*) FILTER (
                WHERE f.account_status = 'REJECTED'
            ) AS rejected_count,

            COUNT(*) FILTER (
                WHERE f.account_status = 'ON_HOLD'
            ) AS on_hold_count

        FROM filtered f
        GROUP BY f.customer_number
    ),

    customer_filter AS
    (
        SELECT
            l.customer_number
        FROM latest l
        WHERE
            p_account_status IS NULL
            OR l.latest_account_status = p_account_status
    ),

    numbered AS
    (
        SELECT
            f.*,
            cc.total_accounts,
            cc.primary_account,
            cc.approved_count,
            cc.pending_count,
            cc.rejected_count,
            cc.on_hold_count,
            l.latest_account_status,

            COUNT(*) OVER () AS total_users

        FROM filtered f

        INNER JOIN customer_filter cf
            ON cf.customer_number = f.customer_number

        INNER JOIN customer_counts cc
            ON cc.customer_number = f.customer_number

        INNER JOIN latest l
            ON l.customer_number = f.customer_number
    )

    SELECT
        n.*,

        CEIL(
            n.total_users::NUMERIC / v_limit
        )::INTEGER AS total_pages,

        v_page AS current_page,
        v_limit AS per_page

    FROM numbered n

    ORDER BY
        n.customer_number ASC,
        n."createdAt" DESC,
        n.id DESC

    LIMIT v_limit
    OFFSET v_offset;

END;
$$;

63.
/* ============================================================
   SP NAME        : sp_create_on_hold_reason

   NODE.JS FUNCTION : createOnHoldReason()

   PURPOSE :
   Create an ON_HOLD reason and its email template.

   API ROUTE :
   Admin ON_HOLD reason creation route

   ACCESS :
   Private - ADMIN / SUPER_ADMIN

   DATABASE TABLE :
   reason_templates

   ============================================================ */

DROP PROCEDURE IF EXISTS sp_create_on_hold_reason(
    TEXT,
    TEXT,
    VARCHAR,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "user"."sp_kyc_admin_reset"(
    IN p_identifier VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql AS $$
DECLARE v_user_id INTEGER; v_customer_number VARCHAR(191); v_deleted INTEGER;
BEGIN
    SET LOCAL search_path TO "user", public;
    SELECT u."id", u."customer_number" INTO v_user_id, v_customer_number
    FROM "user"."user" u
    WHERE (p_identifier ~ '^[0-9]+$' AND u."id"=p_identifier::INTEGER)
       OR u."email"=p_identifier
       OR u."customer_number"=p_identifier
    LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found with identifier: %', p_identifier; END IF;

    DELETE FROM "kyc"."kyc" WHERE "customer_number"=v_customer_number;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    UPDATE "user"."user" SET "is_kyc_verified"=FALSE,"kyc_status"=NULL,"updated_at"=CURRENT_TIMESTAMP WHERE "id"=v_user_id;

    OPEN p_cursor FOR SELECT u."id",u."email",u."customer_number",u."is_kyc_verified",u."kyc_status",u."phone_prefix",v_deleted AS deleted_records FROM "user"."user" u WHERE u."id"=v_user_id;
END;
$$;

74.
-- ---------------------------------------------------------------
-- sp_kyc_admin_verify
-- Source function: adminVerifyKyc
-- Purpose: Verifies the user and updates the newest KYC row, or creates one.
-- ---------------------------------------------------------------

CREATE OR REPLACE PROCEDURE "user"."sp_buy_get_user"(
    p_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT u.* FROM "user"."user" u WHERE u.customer_number = p_customer_number LIMIT 1;
END $$;

-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.wallet.findFirst(...)
-- Purpose: Fetch and lock the active wallet used by buy/sell flows.

CREATE OR REPLACE PROCEDURE "user"."sp_get_all_withdrawals"(
    p_page integer DEFAULT 1,
    p_limit integer DEFAULT 20,
    p_search varchar DEFAULT NULL,
    p_status varchar DEFAULT NULL,
    p_customer_number varchar DEFAULT NULL,
    p_currency varchar DEFAULT NULL,
    p_export boolean DEFAULT false,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT w.*, b.bank_name, b.account_number, b.holder_name, b.branch_name,
       u.customer_number AS user_customer_number,
       count(*) OVER() AS total_count
FROM "payments"."withdrawal" w
JOIN "kyc"."bank_verification" b ON b.id = w.bank_verification_id
LEFT JOIN "user"."user" u ON u.customer_number = w.customer_number
WHERE w.is_active = true
  AND (p_status IS NULL OR w.status::text = p_status)
  AND (p_customer_number IS NULL OR w.customer_number = p_customer_number)
  AND (p_currency IS NULL OR w.currency = p_currency)
  AND (p_search IS NULL OR w.customer_number ILIKE '%'||p_search||'%'
       OR w.withdrawal_id ILIKE '%'||p_search||'%'
       OR COALESCE(w.transaction_reference,'') ILIKE '%'||p_search||'%'
       OR b.bank_name ILIKE '%'||p_search||'%'
       OR b.holder_name ILIKE '%'||p_search||'%'
       OR b.account_number ILIKE '%'||p_search||'%')
ORDER BY w.requested_at DESC
OFFSET CASE WHEN p_export THEN 0 ELSE (GREATEST(p_page,1)-1)*p_limit END
LIMIT CASE WHEN p_export THEN NULL ELSE p_limit END;
END $$;

-- Function: getUserWithdrawals
-- Prisma await: await prisma.withdrawal.findMany(...)
-- Prisma await: await prisma.withdrawal.count(...)
-- Purpose: Fetch withdrawals for one customer.
