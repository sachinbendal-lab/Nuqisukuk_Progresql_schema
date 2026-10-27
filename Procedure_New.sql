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

CREATE OR REPLACE PROCEDURE "ops"."admin_login_sp"(
    IN p_email TEXT,
    INOUT v_status_code INT DEFAULT 200,
    INOUT v_error_msg TEXT DEFAULT NULL,
    INOUT p_result_cursor REFCURSOR DEFAULT 'admin_login_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id INT;
    v_is_deleted BOOLEAN;
    v_is_active BOOLEAN;
BEGIN
    -- 1. Fetch active status tracking fields based on the matching email string
    SELECT id, is_deleted, is_active 
    INTO v_id, v_is_deleted, v_is_active
    FROM "ops"."admin_user" 
    WHERE email = p_email;

    -- 2. Validation: Check if the user record exists at all
    IF v_id IS NULL THEN
        v_status_code := 401;
        v_error_msg := 'Invalid email or password. Please try again.';
        RETURN;
    END IF;

    -- 3. Validation: Verify that the account is active and not soft-deleted
    IF v_is_deleted = TRUE OR v_is_active = FALSE THEN
        v_status_code := 401;
        v_error_msg := 'Invalid email or password. Please try again.';
        RETURN;
    END IF;

    -- 4. Open the dynamic result cursor to safely transmit the complete flat admin row for bcrypt matching
    OPEN p_result_cursor FOR
    SELECT 
        id, 
        "userId", 
        email, 
        password, -- Returned to application runtime for bcrypt evaluation
        first_name, 
        last_name, 
        role::TEXT AS role, 
        token_version
    FROM "ops"."admin_user"
    WHERE id = v_id;

    -- Signal completion
    v_status_code := 200;
    v_error_msg := NULL;
END;
$$;


--function - adminRefreshToken

CREATE OR REPLACE PROCEDURE "ops"."admin_refresh_update_sp"(
    IN p_id INT,                      
    IN p_client_secret TEXT,          
    IN p_secret_expires TIMESTAMP,    
    INOUT p_result_cursor REFCURSOR DEFAULT 'refresh_update_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN
   
    UPDATE "ops"."admin_user"
    SET 
        client_secret = p_client_secret,
        secret_expires = p_secret_expires,
        updated_at = CURRENT_TIMESTAMP(3)
    WHERE id = p_id;

   
    OPEN p_result_cursor FOR
    SELECT 
        id, 
        "userId", 
        email, 
        first_name, 
        last_name, 
        role::TEXT AS role
    FROM "ops"."admin_user"
    WHERE id = p_id;
END;
$$;

--function - adminLogout

CREATE OR REPLACE PROCEDURE "ops"."admin_logout"(
    IN p_admin_id INT,              
    IN p_token_hash TEXT            
)
LANGUAGE plpgsql
AS $$
BEGIN
    
    UPDATE "ops"."admin_user" 
    SET 
        client_secret = NULL,
        secret_expires = NULL,
        updated_at = CURRENT_TIMESTAMP(3)
    WHERE id = p_admin_id;

    
END;
$$;

--function - adminLogoutAll

CREATE OR REPLACE PROCEDURE "ops"."admin_logout_all_sp"(
    IN p_admin_id INT,               
    IN p_admin_user_id TEXT          
)
LANGUAGE plpgsql
AS $$
BEGIN
    
    DELETE FROM "user"."refresh_tokens" 
    WHERE user_id = p_admin_user_id; 

   
    UPDATE "ops"."admin_user"
    SET 
        client_secret = NULL,
        secret_expires = NULL,
        updated_at = CURRENT_TIMESTAMP(3)
    WHERE id = p_admin_id;

END;
$$;

--function - getDashboardCounts

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

CREATE OR REPLACE PROCEDURE "trade"."export_transactions_csv_proc"(
    IN p_type TEXT,
    IN p_status TEXT,
    INOUT p_csv_output TEXT DEFAULT NULL
)
AS $$
DECLARE
    v_headers TEXT;
    v_rows TEXT;
    v_err_msg TEXT;
BEGIN
    -- 1. Setup the 17 column layout structured spreadsheet headers
    v_headers := '"Transaction ID","Customer Number","Transaction Type","Sukuk Name","Issuer","ISIN","Quantity","Price Per Unit","Accrued Interest","Blox Value","Total Amount","Currency","Status","Transaction Date","Wallet Balance Before","Wallet Balance After","Notes"';

    -- 2. Execute relational join and aggregate data fields straight into a single CSV block text string
    SELECT string_agg(
        '"' || COALESCE(tx.transaction_id, '') || '",' ||
        '"' || COALESCE(tx.customer_number, '') || '",' ||
        '"' || COALESCE(tx.transaction_type::text, '') || '",' ||
        '"' || COALESCE(si.name, '') || '",' ||
        '"' || COALESCE(si.issuer, '') || '",' ||
        '"' || COALESCE(si.isin, '') || '",' ||
        '"' || COALESCE(tx.quantity::text, '0') || '",' ||
        '"' || TO_CHAR(tx.price_per_unit, 'FM999999999999990.00') || '",' ||
        '"' || TO_CHAR(tx.accrued_interest, 'FM999999999999990.00') || '",' ||
        '"' || TO_CHAR(tx.blox_value, 'FM999999999999990.00') || '",' ||
        '"' || TO_CHAR(tx.total_amount, 'FM999999999999990.00') || '",' ||
        '"' || COALESCE(tx.currency, '') || '",' ||
        '"' || COALESCE(tx.status::text, '') || '",' || -- Cast status enum to text safely
        '"' || TO_CHAR(tx.transaction_date, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') || '精度",' ||
        '"' || TO_CHAR(tx.wallet_balance_before, 'FM999999999999990.00') || '精度",' ||
        '"' || TO_CHAR(tx.wallet_balance_after, 'FM999999999999990.00') || '精度",' ||
        '"' || COALESCE(tx.notes, '') || '"',
        CHR(10) ORDER BY tx.transaction_date DESC
    )
    INTO v_rows
    FROM "trade"."transaction" tx
    INNER JOIN "trade"."sukuk_inventory" si ON tx.sukuk_id = si.id -- Adjusted foreign key context link mapping
    WHERE (p_type = 'all' OR tx.transaction_type::text = p_type)
      AND (p_status = 'all' OR tx.status::text = p_status);

    -- 3. Combine header line item and data grid rows with carriage line feeds
    p_csv_output := v_headers || CHR(10) || COALESCE(v_rows, '');

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT;
    p_csv_output := 'ERROR: ' || v_err_msg;
END;
$$ LANGUAGE plpgsql;

--function - assignPermissions

CREATE OR REPLACE PROCEDURE "ops"."assign_permissions_sp"(
    IN p_user_id TEXT,                 
    IN p_permissions_json JSONB,       
    INOUT p_result_cursor REFCURSOR DEFAULT 'permissions_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_admin_id INT;
    v_next_id TEXT; 
    item RECORD;
BEGIN
    
    SELECT id INTO v_admin_id FROM "ops"."admin_user" WHERE "userId" = p_user_id;

    IF v_admin_id IS NULL THEN
        OPEN p_result_cursor FOR SELECT * FROM "ops"."permissions" WHERE FALSE;
        RETURN;
    END IF;

    FOR item IN 
        SELECT 
            module_name,
            can_create::INT AS can_create,
            can_read::INT AS can_read,
            can_update::INT AS can_update,
            can_delete::INT AS can_delete,
            COALESCE(can_activate, 0)::INT AS can_activate,
            COALESCE(can_deactivate, 0)::INT AS can_deactivate
        FROM jsonb_to_recordset(p_permissions_json) AS x(
            module_name TEXT,
            can_create INT,        
            can_read INT,
            can_update INT,
            can_delete INT,
            can_activate INT,
            can_deactivate INT
        )
    LOOP
        PERFORM 1 FROM "ops"."permissions" 
        WHERE admin_user_id = v_admin_id AND module_name = item.module_name;

        IF FOUND THEN
            UPDATE "ops"."permissions"
            SET 
                can_create = item.can_create,
                can_read = item.can_read,
                can_update = item.can_update,
                can_delete = item.can_delete,
                can_activate = item.can_activate, 
                can_deactivate = item.can_deactivate, 
                updated_at = CURRENT_TIMESTAMP(3) 
            WHERE admin_user_id = v_admin_id AND module_name = item.module_name;
        ELSE
            v_next_id := LOWER(CONCAT('cmja', SUBSTRING(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 21)));

            INSERT INTO "ops"."permissions" (
                id, admin_user_id, module_name, can_create, can_read, 
                can_update, can_delete, can_activate, can_deactivate,
                created_at, updated_at 
            )
            VALUES (
                v_next_id, 
                v_admin_id, 
                item.module_name, 
                item.can_create, 
                item.can_read, 
                item.can_update, 
                item.can_delete, 
                item.can_activate, 
                item.can_deactivate,
                CURRENT_TIMESTAMP(3), 
                CURRENT_TIMESTAMP(3)
            );
        END IF;
    END LOOP;

    OPEN p_result_cursor FOR
    SELECT 
        id,
        admin_user_id,
        module_name,
        can_create,
        can_read,
        can_update,
        can_delete,
        created_at,
        updated_at,
        can_activate,
        can_deactivate
    FROM "ops"."permissions"
    WHERE admin_user_id = v_admin_id;
END;
$$;

--function -getUserPermissions

CREATE OR REPLACE PROCEDURE "ops"."get_user_permissions_sp"(
    IN p_target_user_id TEXT,        
    IN p_req_user_id INT,             
    IN p_req_user_role TEXT,         
    INOUT p_result_cursor REFCURSOR DEFAULT 'user_permissions_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_id INT;
    v_target_role TEXT;
BEGIN
  
    SELECT id, role::TEXT 
    INTO v_target_id, v_target_role
    FROM "ops"."admin_user" 
    WHERE "userId" = p_target_user_id;

  
    IF v_target_id IS NULL THEN
        OPEN p_result_cursor FOR SELECT * FROM "ops"."permissions" WHERE FALSE;
        RETURN;
    END IF;

  
    IF p_req_user_role = 'ADMIN' AND v_target_id <> p_req_user_id THEN
        OPEN p_result_cursor FOR SELECT * FROM "ops"."permissions" WHERE FALSE;
        RETURN;
    END IF;

  
    OPEN p_result_cursor FOR
    SELECT 
        au.id AS admin_user_id,
        au."userId",
        au.role::TEXT AS user_role,
        p.id AS permission_id,
        p.module_name,
        p.can_create,
        p.can_read,
        p.can_update,
        p.can_delete,
        p.can_activate,
        p.can_deactivate,
        p.created_at,
        p.updated_at
    FROM "ops"."admin_user" au
    LEFT JOIN "ops"."permissions" p ON p.admin_user_id = au.id
    WHERE au.id = v_target_id;
END;
$$;

--function -removePermission

CREATE OR REPLACE PROCEDURE "ops"."remove_permission_sp"(
    IN p_permission_id TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    
    DELETE FROM "ops"."permissions" 
    WHERE id = p_permission_id;
END;
$$;

--function - removeAllUserPermissions

CREATE OR REPLACE PROCEDURE "ops"."remove_all_user_permissions_sp"(
    IN p_user_id TEXT,
    INOUT p_removed_count INT DEFAULT 0
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_admin_id INT;
BEGIN

    SELECT id INTO v_admin_id FROM "ops"."admin_user" WHERE "userId" = p_user_id;


    IF v_admin_id IS NULL THEN
        p_removed_count := 0;
        RETURN;
    END IF;


    DELETE FROM "ops"."permissions" 
    WHERE admin_user_id = v_admin_id;


    GET DIAGNOSTICS p_removed_count = ROW_COUNT;
END;
$$;

--function - getAvailableModules

CREATE OR REPLACE PROCEDURE "ops"."get_available_modules_sp"(
    INOUT p_result_cursor REFCURSOR DEFAULT 'modules_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN

	OPEN p_result_cursor FOR
    SELECT * FROM (
        VALUES 
        ('users', 'User management - create, view, update, and delete users', ARRAY['create', 'read', 'update', 'delete']::TEXT[]),
        ('inventory', 'Sukuk inventory management - manage investment products', ARRAY['create', 'read', 'update', 'delete']::TEXT[]),
        ('transactions', 'Transaction management - view and manage user transactions', ARRAY['create', 'read', 'update', 'delete']::TEXT[]),
        ('wallet', 'Wallet management - view and manage user wallets', ARRAY['create', 'read', 'update', 'delete']::TEXT[]),
        ('withdraw', 'Withdrawal management - view and manage withdrawal requests', ARRAY['create', 'read', 'update', 'delete']::TEXT[]),
        ('permissions', 'Permission management - assign and manage user permissions', ARRAY['create', 'read', 'update', 'delete']::TEXT[])
    ) AS m(name, description, actions);
END;
$$;


--function - getMyPermissions

CREATE OR REPLACE PROCEDURE "ops"."get_my_permissions_sp"(
    IN p_req_user_id INT,             
    INOUT p_result_cursor REFCURSOR DEFAULT 'my_permissions_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN
    
    OPEN p_result_cursor FOR
    SELECT 
        id,
        admin_user_id,
        module_name,
        can_create,
        can_read,
        can_update,
        can_delete,
        can_activate,
        can_deactivate,
        created_at,
        updated_at
    FROM "ops"."permissions"
    WHERE admin_user_id = p_req_user_id;
END;
$$;


--function - bulkAssignPermissions

CREATE OR REPLACE PROCEDURE "ops"."bulk_assign_permissions_sp"(
    IN p_user_id TEXT,                 
    IN p_template_permissions JSONB,       
    INOUT p_result_cursor REFCURSOR DEFAULT 'bulk_permissions_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_admin_id INT;
    v_next_id TEXT; 
    item RECORD;
BEGIN
    -- 1. Fetch internal numeric ID from "ops"."admin_user" table
    SELECT id INTO v_admin_id FROM "ops"."admin_user" WHERE "userId" = p_user_id;

    -- 2. Silent Fail-safe: If target user profile doesn't exist, exit safely with an empty cursor
    IF v_admin_id IS NULL THEN
        OPEN p_result_cursor FOR SELECT * FROM "ops"."permissions" WHERE FALSE;
        RETURN;
    END IF;

    -- 3. Loop Upsert: Handles template mappings with 1 and 0 integers across all columns
    FOR item IN 
        SELECT 
            module_name,
            can_create::INT AS can_create,
            can_read::INT AS can_read,
            can_update::INT AS can_update,
            can_delete::INT AS can_delete,
            COALESCE(can_activate, 0)::INT AS can_activate,
            COALESCE(can_deactivate, 0)::INT AS can_deactivate
        FROM jsonb_to_recordset(p_template_permissions) AS x(
            module_name TEXT,
            can_create INT,        
            can_read INT,
            can_update INT,
            can_delete INT,
            can_activate INT,
            can_deactivate INT
        )
    LOOP
        -- Check if a record already exists for this admin user and module combo
        PERFORM 1 FROM "ops"."permissions" 
        WHERE admin_user_id = v_admin_id AND module_name = item.module_name;

        IF FOUND THEN
            -- Update existing row using strict integer metrics
            UPDATE "ops"."permissions"
            SET 
                can_create = item.can_create,
                can_read = item.can_read,
                can_update = item.can_update,
                can_delete = item.can_delete,
                can_activate = item.can_activate,
                can_deactivate = item.can_deactivate,
                updated_at = CURRENT_TIMESTAMP(3) 
            WHERE admin_user_id = v_admin_id AND module_name = item.module_name;
        ELSE
            -- Dynamically generates unique Prisma CUID strings (e.g., cmja...)
            v_next_id := LOWER(CONCAT('cmja', SUBSTRING(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 21)));

            -- Insert clean numeric data rows matching the integer data types
            INSERT INTO "ops"."permissions" (
                id, admin_user_id, module_name, can_create, can_read, 
                can_update, can_delete, can_activate, can_deactivate,
                created_at, updated_at 
            )
            VALUES (
                v_next_id, v_admin_id, item.module_name, 
                item.can_create, item.can_read, item.can_update, item.can_delete, 
                item.can_activate, item.can_deactivate,
                CURRENT_TIMESTAMP(3), CURRENT_TIMESTAMP(3)
            );
        END IF;
    END LOOP;

    -- 4. Open transaction cursor pointing directly to the updated columns
    OPEN p_result_cursor FOR
    SELECT 
        id, admin_user_id, module_name, 
        can_create, can_read, can_update, can_delete, 
        created_at, updated_at, can_activate, can_deactivate
    FROM "ops"."permissions"
    WHERE admin_user_id = v_admin_id;
END;
$$;

--function - getPermissionTemplates

CREATE OR REPLACE PROCEDURE "ops"."get_permission_templates_sp"(
    INOUT p_result_cursor REFCURSOR DEFAULT 'templates_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN

OPEN p_result_cursor FOR
    SELECT * FROM (
        VALUES 
        ('full_access', 'Full access to all modules (Create, Read, Update, Delete)', ARRAY['users', 'inventory', 'transactions', 'wallet', 'withdraw', 'permissions']::TEXT[]),
        ('read_only', 'Read-only access to all modules', ARRAY['users', 'inventory', 'transactions', 'wallet', 'withdraw', 'permissions']::TEXT[]),
        ('transaction_manager', 'Manage transactions and view inventory/wallets', ARRAY['transactions (full)', 'inventory (read)', 'wallet (read)']::TEXT[]),
        ('inventory_manager', 'Full access to inventory management', ARRAY['inventory (full)']::TEXT[])
    ) AS t(template_key, description, modules);
END;
$$;

--function - getUserSessions

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

CREATE OR REPLACE PROCEDURE "ops"."force_logout_user_proc"(
	IN p_user_id character varying,
	IN p_admin_email character varying,
	IN p_admin_name character varying,
	IN p_ip_address character varying,
	IN p_browser text,
	IN p_metadata jsonb,
	INOUT p_result json DEFAULT NULL::json)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_user_exists BOOLEAN;
    v_user_email VARCHAR(191);
    v_user_first_name VARCHAR(191);
    v_user_last_name VARCHAR(191);
    v_full_metadata JSONB;
    v_current_time TIMESTAMP(3) WITHOUT TIME ZONE := NOW()::timestamp(3);
    v_next_id INT; 
    v_err_msg TEXT;
    v_err_detail TEXT;
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

    UPDATE "user"."refresh_tokens"
    SET revoked_at = v_current_time, revoked_reason = 'Admin terminated all active sessions for this user'
    WHERE user_id = p_user_id AND user_type = 'user' AND revoked_at IS NULL;

    v_full_metadata := p_metadata || JSONB_BUILD_OBJECT(
        'targetUserId', p_user_id,
        'targetEmail', COALESCE(v_user_email, NULL),
        'targetName', NULLIF(TRIM(CONCAT(v_user_first_name, ' ', v_user_last_name)), ''),
        'terminatedAt', TO_CHAR(v_current_time, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    );

    SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_id FROM "ops"."audit_logs";

INSERT INTO "ops"."audit_logs" (id,module,"actionType","entityType","entityId","statusBefore","statusAfter","actionReason","adminEmail","adminName","ipAddress", browser, success,metadata,"createdAt") 
VALUES ( v_next_id, 'Sessions','Force Logout','User Account', p_user_id,'active','terminated','Admin terminated all active sessions for this user', p_admin_email,p_admin_name,p_ip_address,p_browser
,TRUE, v_full_metadata,v_current_time );

  
    p_result := JSON_BUILD_OBJECT(
        'success', TRUE,
        'message', 'All sessions terminated'
    );

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_detail = PG_EXCEPTION_DETAIL;
    RAISE NOTICE 'CRITICAL INTERNAL DB ERROR: % | DETAIL: %', v_err_msg, v_err_detail;
    p_result := JSON_BUILD_OBJECT('success', FALSE, 'error', v_err_msg, 'code', 500);
END;
$BODY$;

--function - getActiveSessionUsers

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

CREATE OR REPLACE PROCEDURE "ops"."create_admin_user"(
    p_email TEXT,
    p_phone_number TEXT,
    p_phone_prefix TEXT,
    p_first_name TEXT,
    p_last_name TEXT,
    p_hashed_password TEXT,
    p_role TEXT,
    p_gender TEXT,
    p_creator_admin_id INT,
    p_creator_email TEXT,
    INOUT p_result REFCURSOR DEFAULT 'created_user_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_id INT;
    v_customer_number VARCHAR(191);
    v_user_id VARCHAR(191);
    v_wallet_id VARCHAR(191);
    v_next_wallet_id INT;
BEGIN
    -- Validation Checks
    IF (p_email IS NULL OR p_email = '') AND (p_phone_number IS NULL OR p_phone_number = '') THEN
        RAISE EXCEPTION 'Provide either email or phone number';
    END IF;

    IF p_hashed_password IS NULL OR p_hashed_password = '' THEN
        RAISE EXCEPTION 'Password is required';
    END IF;

    IF p_role NOT IN ('READ_ONLY', 'ADMIN', 'SUPER_ADMIN', 'USER') THEN
        RAISE EXCEPTION 'Invalid role';
    END IF;

    -- BRANCH A: ADMIN USER
    IF p_role IN ('ADMIN', 'READ_ONLY', 'SUPER_ADMIN') THEN
        IF (p_email IS NOT NULL AND p_email <> '' AND EXISTS (SELECT 1 FROM "ops"."admin_user" WHERE email = p_email))
           OR
           (p_phone_number IS NOT NULL AND p_phone_number <> '' AND EXISTS (SELECT 1 FROM "ops"."admin_user" WHERE phone_number = p_phone_number)) THEN
            RAISE EXCEPTION 'Admin email or phone number already exists';
        END IF;

        INSERT INTO "ops"."admin_user" (
            email, phone_number, phone_prefix, first_name, last_name,
            password, role, created_by, is_active,
            is_email_verified, is_phone_verified, gender,
            "userId", created_at, updated_at
        )
        VALUES (
            NULLIF(p_email, ''),
            NULLIF(p_phone_number, ''),
            CASE WHEN NULLIF(p_phone_number, '') IS NULL THEN NULL ELSE p_phone_prefix END,
            p_first_name, p_last_name, p_hashed_password, 
            p_role::admin_user_role,
            p_creator_admin_id, 
            TRUE,
            CASE WHEN NULLIF(p_email, '') IS NULL THEN FALSE ELSE TRUE END,
            CASE WHEN NULLIF(p_phone_number, '') IS NULL THEN FALSE ELSE TRUE END,
            p_gender::admin_user_gender, -- Cast explicitly to admin_user_gender for this table
            REPLACE(gen_random_uuid()::TEXT, '-', ''),
            CURRENT_TIMESTAMP(3), CURRENT_TIMESTAMP(3)
        )
        RETURNING id INTO v_new_id;

        v_customer_number := 'NUQI' || lpad(v_new_id::TEXT, 8, '0');

        UPDATE "ops"."admin_user"
        SET customer_number = v_customer_number,
            updated_at = CURRENT_TIMESTAMP(3)
        WHERE id = v_new_id;

        OPEN p_result FOR
        SELECT id, "userId", email, phone_number, first_name, last_name,
               role, customer_number, is_active, created_at, created_by
        FROM "ops"."admin_user"
        WHERE id = v_new_id;

    -- BRANCH B: REGULAR USER
    ELSE
        IF (p_email IS NOT NULL AND p_email <> '' AND EXISTS (SELECT 1 FROM "user"."user" WHERE email = p_email))
           OR
           (p_phone_number IS NOT NULL AND p_phone_number <> '' AND EXISTS (SELECT 1 FROM "user"."user" WHERE phone_number = p_phone_number)) THEN
            RAISE EXCEPTION 'User email or phone number already exists';
        END IF;

        INSERT INTO "user"."user" (
            email, phone_number, phone_prefix, first_name, last_name,
            password, role, created_by, is_active,
            is_email_verified, is_phone_verified, gender,
            "userId", created_at, updated_at
        )
        VALUES (
            NULLIF(p_email, ''),
            NULLIF(p_phone_number, ''),
            CASE WHEN NULLIF(p_phone_number, '') IS NULL THEN NULL ELSE p_phone_prefix END,
            p_first_name, p_last_name, p_hashed_password, 
            'USER',
            p_creator_email, 
            TRUE,
            CASE WHEN NULLIF(p_email, '') IS NULL THEN FALSE ELSE TRUE END,
            CASE WHEN NULLIF(p_phone_number, '') IS NULL THEN FALSE ELSE TRUE END,
            p_gender::gender_enum, -- Keeps using gender_enum for the user table
            REPLACE(gen_random_uuid()::TEXT, '-', ''),
            CURRENT_TIMESTAMP(3), CURRENT_TIMESTAMP(3)
        )
        RETURNING id INTO v_new_id;

        v_customer_number := 'NUQI' || lpad(v_new_id::TEXT, 8, '0');

        UPDATE "user"."user"
        SET customer_number = v_customer_number,
            updated_at = CURRENT_TIMESTAMP(3)
        WHERE id = v_new_id;

        v_wallet_id := REPLACE(gen_random_uuid()::TEXT, '-', '');

        SELECT COALESCE(MAX(id), 0) + 1 INTO v_next_wallet_id FROM "payments"."wallet";

        INSERT INTO "payments"."wallet" (
            id, "walletId", customer_number, balance, currency,
            status, is_active, created_at, updated_at
        )
        VALUES (
            v_next_wallet_id, v_wallet_id, v_customer_number, 0.00, 'USD',
            'ACTIVE', TRUE, CURRENT_TIMESTAMP(3), CURRENT_TIMESTAMP(3)
        );

        OPEN p_result FOR
        SELECT id, "userId", email, phone_number, first_name, last_name,
               role, customer_number, is_active, created_at, created_by
        FROM "user"."user"
        WHERE id = v_new_id;
    END IF;

END;
$$;

--function - getAllUsers

CREATE OR REPLACE PROCEDURE "ops"."get_all_users"(
    p_role VARCHAR(30),
    p_search VARCHAR(255),
    INOUT p_result_list REFCURSOR DEFAULT 'users_list_cursor',  -- Opens stream for DATA ROWS
    INOUT p_result_count REFCURSOR DEFAULT 'users_count_cursor' -- Opens stream for TOTAL COUNT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_search VARCHAR(255);
BEGIN
    -- 1. Direct search string assignment (trims space and catches empty inputs)
    v_search := NULLIF(TRIM(p_search), '');

    -- ===================================================
    -- BRANCH 1: ROLE IS 'USER' (Queries data and count for regular users)
    -- ===================================================
    IF p_role = 'USER' THEN
        
        -- Cursor 1: Fetches actual user profile fields (DATA)
        OPEN p_result_list FOR
        SELECT
            id, "userId", email, phone_number, phone_prefix, first_name, last_name,
            role, customer_number, is_active, is_kyc_verified,
            is_phone_verified, is_email_verified, created_at, created_by
        FROM "user"."user"
        WHERE is_deleted = FALSE
          AND role::TEXT = 'USER'
          AND (
              v_search IS NULL
              OR email LIKE '%' || v_search || '%'
              OR phone_number LIKE '%' || v_search || '%'
              OR first_name LIKE '%' || v_search || '%'
              OR last_name LIKE '%' || v_search || '%'
              OR customer_number LIKE '%' || v_search || '%'
          )
        ORDER BY created_at DESC;

        -- Cursor 2: Fetches total number integer (COUNT)
        OPEN p_result_count FOR
        SELECT COUNT(*) AS total
        FROM "user"."user"
        WHERE is_deleted = FALSE
          AND role::TEXT = 'USER'
          AND (
              v_search IS NULL
              OR email LIKE '%' || v_search || '%'
              OR phone_number LIKE '%' || v_search || '%'
              OR first_name LIKE '%' || v_search || '%'
              OR last_name LIKE '%' || v_search || '%'
              OR customer_number LIKE '%' || v_search || '%'
          );

    -- ===================================================
    -- BRANCH 2: ROLE IS ADMIN / SUPER_ADMIN / READ_ONLY
    -- ===================================================
    ELSIF p_role IN ('READ_ONLY', 'ADMIN', 'SUPER_ADMIN') THEN
        
        -- Cursor 1: Fetches admin fields (DATA)
        OPEN p_result_list FOR
        SELECT
            id, "userId", email, phone_number, phone_prefix, first_name, last_name,
            role, customer_number, is_active, is_phone_verified,
            is_email_verified, created_at, created_by
        FROM "ops"."admin_user"
        WHERE is_deleted = FALSE
          AND role::TEXT = p_role
          AND (
              v_search IS NULL
              OR email LIKE '%' || v_search || '%'
              OR phone_number LIKE '%' || v_search || '%'
              OR first_name LIKE '%' || v_search || '%'
              OR last_name LIKE '%' || v_search || '%'
              OR customer_number LIKE '%' || v_search || '%'
          )
        ORDER BY created_at DESC;

        -- Cursor 2: Fetches total matching admin count (COUNT)
        OPEN p_result_count FOR
        SELECT COUNT(*) AS total
        FROM "ops"."admin_user"
        WHERE is_deleted = FALSE
          AND role::TEXT = p_role
          AND (
              v_search IS NULL
              OR email LIKE '%' || v_search || '%'
              OR phone_number LIKE '%' || v_search || '%'
              OR first_name LIKE '%' || v_search || '%'
              OR last_name LIKE '%' || v_search || '%'
              OR customer_number LIKE '%' || v_search || '%'
          );

    -- ===================================================
    -- BRANCH 3: NO ROLE SPECIFIED (UNION BOTH TABLES)
    -- ===================================================
    ELSE
        
        -- Cursor 1: Merges regular and admin users into one large array (DATA)
        OPEN p_result_list FOR
        SELECT
            id, "userId", email, phone_number, phone_prefix, first_name, last_name,
            role, customer_number, is_active, is_kyc_verified,
            is_phone_verified, is_email_verified, created_at, created_by
        FROM (
            SELECT
                id, "userId", email, phone_number, phone_prefix, first_name, last_name,
                role::TEXT, customer_number, is_active, is_kyc_verified,
                is_phone_verified, is_email_verified, created_at, created_by
            FROM "user"."user"
            WHERE is_deleted = FALSE
              AND (
                  v_search IS NULL
                  OR email LIKE '%' || v_search || '%'
                  OR phone_number LIKE '%' || v_search || '%'
                  OR first_name LIKE '%' || v_search || '%'
                  OR last_name LIKE '%' || v_search || '%'
                  OR customer_number LIKE '%' || v_search || '%'
              )

            UNION ALL

            SELECT
                id, "userId", email, phone_number, phone_prefix, first_name, last_name,
                role::TEXT, customer_number, is_active, NULL AS is_kyc_verified,
                is_phone_verified, is_email_verified, created_at, created_by
            FROM "ops"."admin_user"
            WHERE is_deleted = FALSE
              AND (
                  v_search IS NULL
                  OR email LIKE '%' || v_search || '%'
                  OR phone_number LIKE '%' || v_search || '%'
                  OR first_name LIKE '%' || v_search || '%'
                  OR last_name LIKE '%' || v_search || '%'
                  OR customer_number LIKE '%' || v_search || '%'
              )
        ) AS all_users
        ORDER BY created_at DESC;

        -- Cursor 2: Math summation adding user count + admin count together (COUNT)
        OPEN p_result_count FOR
        SELECT
            (
                SELECT COUNT(*)
                FROM "user"."user"
                WHERE is_deleted = FALSE
                  AND (
                      v_search IS NULL
                      OR email LIKE '%' || v_search || '%'
                      OR phone_number LIKE '%' || v_search || '%'
                      OR first_name LIKE '%' || v_search || '%'
                      OR last_name LIKE '%' || v_search || '%'
                      OR customer_number LIKE '%' || v_search || '%'
                  )
            )
            +
            (
                SELECT COUNT(*)
                FROM "ops"."admin_user"
                WHERE is_deleted = FALSE
                  AND (
                      v_search IS NULL
                      OR email LIKE '%' || v_search || '%'
                      OR phone_number LIKE '%' || v_search || '%'
                      OR first_name LIKE '%' || v_search || '%'
                      OR last_name LIKE '%' || v_search || '%'
                      OR customer_number LIKE '%' || v_search || '%'
                  )
            ) AS total;
    END IF;

END;
$$;

--function - getUserById

CREATE OR REPLACE PROCEDURE "ops"."get_user_by_id_sp"(
    IN p_user_id TEXT,
    INOUT v_user_json JSON DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- 1. Try to find the user in the admin_user table first
    SELECT json_build_object(
        'id', au.id,
        'userId', au."userId",
        'email', au.email,
        'phone_number', au.phone_number,
        'phone_prefix', au.phone_prefix,
        'first_name', au.first_name,
        'last_name', au.last_name,
        'gender', au.gender,
        'role', au.role,
        'customer_number', au.customer_number,
        'is_active', au.is_active,
        'is_deleted', au.is_deleted,
        'is_phone_verified', au.is_phone_verified,
        'is_email_verified', au.is_email_verified,
        'created_at', au.created_at,
        'updated_at', au.updated_at,
        'created_by', au.created_by,
        -- Creator Relation (Nested Object)
        'creator', (
            SELECT json_build_object(
                'userId', cr."userId",
                'first_name', cr.first_name,
                'last_name', cr.last_name,
                'email', cr.email
            )
            FROM "ops"."admin_user" cr 
            WHERE cr."userId" = au.created_by::TEXT 
            LIMIT 1
        ),
        -- Permission Relation (Nested Array)
        'Permission', COALESCE((
            SELECT json_agg(json_build_object(
                'id', p.id,
                'module_name', p.module_name,
                'can_create', p.can_create,
                'can_read', p.can_read,
                'can_update', p.can_update,
                'can_delete', p.can_delete
            ))
            FROM "ops"."permissions" p WHERE p.admin_user_id = au.id -- Updated table name to permissions
        ), '[]'::json)
    ) INTO v_user_json
    FROM "ops"."admin_user" au
    WHERE au."userId" = p_user_id;

    -- 2. If not found in admin_user, try the user table
    IF v_user_json IS NULL THEN
        SELECT json_build_object(
            'id', u.id,
            'userId', u."userId",
            'email', u.email,
            'phone_number', u.phone_number,
            'phone_prefix', u.phone_prefix,
            'first_name', u.first_name,
            'last_name', u.last_name,
            'gender', u.gender,
            'role', u.role,
            'customer_number', u.customer_number,
            'is_active', u.is_active,
            'is_deleted', u.is_deleted,
            'is_kyc_verified', u.is_kyc_verified,
            'is_phone_verified', u.is_phone_verified,
            'is_email_verified', u.is_email_verified,
            'is_bank_kyc_verified', u.is_bank_kyc_verified,
            'is_risk_verified', u.is_risk_verified,
            'created_at', u.created_at,
            'updated_at', u.updated_at,
            'created_by', u.created_by
        ) INTO v_user_json
        FROM "user"."user" u 
        WHERE u."userId" = p_user_id;
    END IF;
END;
$$;

--function - updateUser

CREATE OR REPLACE PROCEDURE "ops"."update_user_sp"(
    IN p_user_id TEXT,
    IN p_first_name TEXT DEFAULT NULL,
    IN p_last_name TEXT DEFAULT NULL,
    IN p_email TEXT DEFAULT NULL,
    IN p_phone_number TEXT DEFAULT NULL,
    IN p_phone_prefix TEXT DEFAULT NULL,
    IN p_gender TEXT DEFAULT NULL,
    IN p_role TEXT DEFAULT NULL,
    IN p_is_active BOOLEAN DEFAULT NULL,
    INOUT v_user_json JSON DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_is_admin BOOLEAN := FALSE;
BEGIN
    -- Check if the target user belongs to the admin_user table
    PERFORM 1 FROM "ops"."admin_user" WHERE "userId" = p_user_id;
    IF FOUND THEN
        v_is_admin := TRUE;
    END IF;

    -- Execute update and construct returning data payload
    IF v_is_admin THEN
        UPDATE "ops"."admin_user"
        SET 
            first_name = COALESCE(p_first_name, first_name),
            last_name = COALESCE(p_last_name, last_name),
            email = COALESCE(p_email, email),
            phone_number = COALESCE(p_phone_number, phone_number),
            phone_prefix = COALESCE(p_phone_prefix, phone_prefix),
            gender = COALESCE(p_gender::admin_user_gender, gender),
            role = COALESCE(p_role::admin_user_role, role), -- Changed "Role" to admin_user_role
            is_active = COALESCE(p_is_active, is_active),
            updated_at = NOW()
        WHERE "userId" = p_user_id
        RETURNING json_build_object(
            'id', id,
            'userId', "userId",
            'email', email,
            'phone_number', phone_number,
            'first_name', first_name,
            'last_name', last_name,
            'gender', gender,
            'role', role,
            'customer_number', customer_number,
            'is_active', is_active,
            'updated_at', updated_at
        ) INTO v_user_json;
    ELSE
        UPDATE "user"."user"
        SET 
            first_name = COALESCE(p_first_name, first_name),
            last_name = COALESCE(p_last_name, last_name),
            email = COALESCE(p_email, email),
            phone_number = COALESCE(p_phone_number, phone_number),
            phone_prefix = COALESCE(p_phone_prefix, phone_prefix),
            gender = COALESCE(p_gender::admin_user_gender, gender),
            role = COALESCE(p_role::admin_user_role, role), -- Changed "Role" to admin_user_role
            is_active = COALESCE(p_is_active, is_active),
            updated_at = NOW()
        WHERE "userId" = p_user_id
        RETURNING json_build_object(
            'id', id,
            'userId', "userId",
            'email', email,
            'phone_number', phone_number,
            'first_name', first_name,
            'last_name', last_name,
            'gender', gender,
            'role', role,
            'customer_number', customer_number,
            'is_active', is_active,
            'updated_at', updated_at
        ) INTO v_user_json;
    END IF;
END;
$$;

--function - deleteUser

CREATE OR REPLACE PROCEDURE "ops"."delete_user_sp"(
    IN p_user_id TEXT,
    INOUT v_is_success BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_is_admin BOOLEAN := FALSE;
    v_user_exists BOOLEAN := FALSE;
BEGIN
    -- 1. Check if the target user belongs to the admin_user table
    PERFORM 1 FROM "ops"."admin_user" WHERE "userId" = p_user_id;
    IF FOUND THEN
        v_user_exists := TRUE;
        v_is_admin := TRUE;
    ELSE
        -- 2. If not found in admin_user, check the "user" table
        PERFORM 1 FROM "user"."user" WHERE "userId" = p_user_id;
        IF FOUND THEN
            v_user_exists := TRUE;
        END IF;
    END IF;

    -- 3. If user doesn't exist in either table, exit
    IF NOT v_user_exists THEN
        v_is_success := FALSE;
        RETURN;
    END IF;

    -- 4. Perform the soft delete update in the appropriate table
    IF v_is_admin THEN
        UPDATE "ops"."admin_user"
        SET 
            is_deleted = true,
            is_active = false,
            updated_at = NOW()
        WHERE "userId" = p_user_id;
    ELSE
        UPDATE "user"."user"
        SET 
            is_deleted = true,
            is_active = false,
            updated_at = NOW()
        WHERE "userId" = p_user_id;
    END IF;

    -- Flag execution complete successfully
    v_is_success := TRUE;
END;
$$;

--function - getMyCreatedUsers

CREATE OR REPLACE PROCEDURE "ops"."get_my_created_users_sp"(
    IN p_req_user_id TEXT,         
    IN p_req_user_email TEXT,
    INOUT p_result_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN p_result_cursor FOR
    
    -- 1. Fetch from regular lowercase "user" table
    SELECT 
        u.id,
        u."userId",
        u.email,
        u.phone_number,
        u.first_name,
        u.last_name,
        u.role::TEXT AS role,
        u.customer_number,
        u.is_active,
        u.created_at
    FROM "user"."user" u -- Changed to lowercase "user"
    WHERE u.created_by::TEXT = p_req_user_email
      AND u.is_deleted = FALSE

    UNION ALL

    -- 2. Fetch from "ops"."admin_user" table
    SELECT 
        au.id,
        au."userId",
        au.email,
        au.phone_number,
        au.first_name,
        au.last_name,
        au.role::TEXT AS role,
        au.customer_number,
        au.is_active,
        au.created_at
    FROM "ops"."admin_user" au
    WHERE au.created_by::TEXT = p_req_user_id
      AND au.is_deleted = FALSE

    ORDER BY created_at DESC;
END;
$$;


--function  - SetMpin

CREATE OR REPLACE PROCEDURE "ops"."usp_mpin_set"(
    p_user_id   VARCHAR(191),
    p_mpin_hash VARCHAR(255)
) AS $$
BEGIN

INSERT INTO "user".mpin (user_id, mpinhash, created_at, updated_at)
    VALUES (p_user_id, p_mpin_hash, NOW() AT TIME ZONE 'UTC', NOW() AT TIME ZONE 'UTC')
    ON CONFLICT (user_id) 
    DO UPDATE SET 
        mpinhash = EXCLUDED.mpinhash,
        updated_at = NOW() AT TIME ZONE 'UTC';
END;
$$ LANGUAGE plpgsql;

--function - VerifyMpin

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

CREATE OR REPLACE PROCEDURE "ops"."get_gender_enum_values"(
    INOUT p_gender_values TEXT[]
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT array_agg(e.enumlabel::TEXT ORDER BY e.enumsortorder)
    INTO p_gender_values
    FROM pg_type t
    JOIN pg_enum e ON e.enumtypid = t.oid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'Gender'
      AND n.nspname = current_schema();

    IF p_gender_values IS NULL THEN
        p_gender_values := ARRAY[]::TEXT[];
    END IF;
END;
$$;

--function - uploadProfileImage


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

CREATE OR REPLACE PROCEDURE "ops"."get_bank_verification_statuses"(
    INOUT p_enum_values TEXT[]
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT array_agg(e.enumlabel::TEXT ORDER BY e.enumsortorder)
    INTO p_enum_values
    FROM pg_type AS t
    JOIN pg_enum AS e ON e.enumtypid = t.oid
    JOIN pg_namespace AS n ON n.oid = t.typnamespace
    WHERE t.typname = 'bank_account_status'
      AND n.nspname = current_schema();

    IF p_enum_values IS NULL THEN
        p_enum_values := ARRAY[]::TEXT[];
    END IF;
END;
$$;

--function - getRoles

CREATE OR REPLACE PROCEDURE "ops"."get_roles"(
    INOUT p_role_values TEXT[]
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT array_agg(e.enumlabel::TEXT ORDER BY e.enumsortorder)
    INTO p_role_values
    FROM pg_attribute AS a
    JOIN pg_class AS c ON c.oid = a.attrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_type AS t ON t.oid = a.atttypid
    JOIN pg_enum AS e ON e.enumtypid = t.oid
    WHERE c.relname = 'admin_user'
      AND a.attname = 'role'
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND n.nspname = current_schema();

    IF p_role_values IS NULL THEN
        p_role_values := ARRAY[]::TEXT[];
    END IF;
END;
$$;

--function - getRiskLevels

CREATE OR REPLACE PROCEDURE "ops"."get_risk_levels"(
	INOUT p_risk_levels text[])
LANGUAGE 'plpgsql'
AS $BODY$
BEGIN
    SELECT array_agg(e.enumlabel::TEXT ORDER BY e.enumsortorder)
    INTO p_risk_levels
    FROM pg_attribute AS a
    JOIN pg_class AS c ON c.oid = a.attrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_type AS t ON t.oid = a.atttypid
    JOIN pg_enum AS e ON e.enumtypid = t.oid
    WHERE c.relname = 'risk_profile_score_grid'
      AND a.attname = 'risk_level'
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND n.nspname = current_schema();

    IF p_risk_levels IS NULL THEN
        p_risk_levels := ARRAY[]::TEXT[];
    END IF;
END;
$$;


CREATE OR REPLACE PROCEDURE "support"."sp_create_ticket"(
    IN p_customer_number VARCHAR(191),
    IN p_subject VARCHAR(191),
    IN p_description TEXT,
    IN p_category_id VARCHAR(191),
    IN p_subcategory_id VARCHAR(191),
    IN p_priority VARCHAR(50),
    IN p_attachments JSONB,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_ticket_id VARCHAR(191);
    v_ticket_number VARCHAR(191);
    v_sequence INTEGER;
BEGIN
    -- Customer must exist because ticket.customer_number
    -- has a foreign key to user.user.customer_number.
    IF NOT EXISTS (
        SELECT 1
        FROM "user"."user"
        WHERE "customer_number" = p_customer_number
    ) THEN
        RAISE EXCEPTION 'Customer does not exist: %', p_customer_number;
    END IF;

    -- Generate the next ticket number for today.
    SELECT COUNT(*) + 1
    INTO v_sequence
    FROM "support"."ticket"
    WHERE "createdAt"::DATE = CURRENT_DATE;

    v_ticket_number :=
        'TKT'
        || TO_CHAR(CURRENT_DATE, 'YYMMDD')
        || LPAD(v_sequence::TEXT, 4, '0');

    -- Generate a unique ticket ID.
    v_ticket_id := 'c' || REPLACE(GEN_RANDOM_UUID()::TEXT, '-', '');

    -- Create the ticket.
    INSERT INTO "support"."ticket" (
        "id",
        "ticketNumber",
        "customer_number",
        "subject",
        "description",
        "categoryId",
        "subcategoryId",
        "priority",
        "status",
        "attachments",
        "createdAt",
        "updatedAt"
    )
    VALUES (
        v_ticket_id,
        v_ticket_number,
        p_customer_number,
        p_subject,
        p_description,
        p_category_id,
        p_subcategory_id,
        UPPER(COALESCE(p_priority, 'MEDIUM'))::"enum_13",
        'OPEN',
        p_attachments,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );

    -- Return the inserted ticket as normal rows.
    OPEN p_cursor FOR
    SELECT *
    FROM "support"."ticket"
    WHERE "id" = v_ticket_id;
END;
$$;

-------------------------------------------------------------------

2.

-- file -user.ticket.controller.js
-- Purpose:
-- Retrieves the tickets belonging to a specific customer.
-- Supports pagination, filtering by status, category, and priority,
-- searching by ticket number, subject, or description,
-- and returns the matching tickets through a refcursor.

CREATE OR REPLACE PROCEDURE "support"."sp_get_my_tickets"(
    IN p_customer_number VARCHAR(191),
    IN p_page INTEGER,
    IN p_limit INTEGER,
    IN p_status VARCHAR(191),
    IN p_category_id VARCHAR(191),
    IN p_priority VARCHAR(191),
    IN p_search TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_offset INTEGER;
BEGIN
    -- Calculate pagination offset.
    v_offset :=
        (GREATEST(COALESCE(p_page, 1), 1) - 1)
        * GREATEST(COALESCE(p_limit, 10), 1);

    -- Return matching tickets through a cursor.
    OPEN p_cursor FOR
    SELECT
        t.*
    FROM "support"."ticket" AS t
    WHERE t."customer_number" = p_customer_number

      -- Optional status filter.
      AND (
          p_status IS NULL
          OR t."status" = UPPER(p_status)
      )

      -- Optional category filter.
      AND (
          p_category_id IS NULL
          OR t."categoryId" = p_category_id
      )

      -- Optional priority filter.
      AND (
          p_priority IS NULL
          OR t."priority"::TEXT = UPPER(p_priority)
      )

      -- Optional search filter.
      AND (
          p_search IS NULL
          OR t."ticketNumber" ILIKE '%' || p_search || '%'
          OR t."subject" ILIKE '%' || p_search || '%'
          OR t."description" ILIKE '%' || p_search || '%'
      )

    ORDER BY t."createdAt" DESC
    OFFSET v_offset
    LIMIT COALESCE(p_limit, 10);
END;
$$;

3.
-------------------------------------------------------------------------

-- file -user.ticket.controller.js
-- Purpose:
-- Retrieves the details of a specific support ticket belonging to
-- a specific customer, along with the ticket's public comments.
-- Internal comments are excluded from the result.

CREATE OR REPLACE PROCEDURE "support"."sp_get_ticket_details"(
    IN p_ticket_id VARCHAR(191),
    IN p_customer_number VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Return ticket details and public comments.
    OPEN p_cursor FOR
    SELECT
        t."id" AS ticket_id,
        t."ticketNumber",
        t."customer_number",
        t."categoryId",
        t."subcategoryId",
        t."subject",
        t."description",
        t."priority",
        t."status",
        t."assignedTo",
        t."resolution",
        t."escalationLevel",
        t."attachments",
        t."firstResponseAt",
        t."resolvedAt",
        t."closedAt",
        t."rating",
        t."ratingFeedback",
        t."ratedAt",
        t."createdAt" AS ticket_created_at,
        t."updatedAt" AS ticket_updated_at,

        c."id" AS comment_id,
        c."message" AS comment_message,
        c."commentBy",
        c."commentType",
        c."isInternal",
        c."attachments" AS comment_attachments,
        c."createdAt" AS comment_created_at,
        c."updatedAt" AS comment_updated_at

    FROM "support"."ticket" AS t
    LEFT JOIN "support"."ticketcomment" AS c
        ON c."ticketId" = t."id"
       AND c."isInternal" = FALSE

    WHERE t."id" = p_ticket_id
      AND t."customer_number" = p_customer_number

    ORDER BY c."createdAt" ASC;
END;
$$;

4.
--------------------------------------------------------------

-- file -user.ticket.controller.js
-- Purpose:
-- Adds a public comment to a customer's support ticket.
-- Verifies that the ticket belongs to the customer, prevents comments
-- on final tickets closed more than 30 days ago, creates the comment,
-- updates the ticket's updatedAt timestamp, and returns the created comment.

CREATE OR REPLACE PROCEDURE "support"."sp_add_ticket_comment"(
    IN p_ticket_id VARCHAR(191),
    IN p_customer_number VARCHAR(191),
    IN p_message TEXT,
    IN p_comment_by VARCHAR(191),
    IN p_attachments JSONB,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_comment_id VARCHAR(191);
    v_ticket_status VARCHAR(191);
    v_ticket_updated_at TIMESTAMP;
BEGIN
    IF p_message IS NULL OR BTRIM(p_message) = '' THEN
        RAISE EXCEPTION 'Comment message is required';
    END IF;

    -- Confirm ticket belongs to the customer.
    SELECT
        t."status",
        t."updatedAt"
    INTO
        v_ticket_status,
        v_ticket_updated_at
    FROM "support"."ticket" AS t
    WHERE t."id" = p_ticket_id
      AND t."customer_number" = p_customer_number;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ticket not found';
    END IF;

    -- Prevent comments on final tickets older than 30 days.
    IF EXISTS (
        SELECT 1
        FROM "support"."ticketstatusconfig" AS s
        WHERE s."name" = v_ticket_status
          AND s."isActive" = TRUE
          AND s."isFinal" = TRUE
          AND v_ticket_updated_at < CURRENT_TIMESTAMP - INTERVAL '30 days'
    ) THEN
        RAISE EXCEPTION
            'Cannot add comments to a ticket closed more than 30 days ago';
    END IF;

    v_comment_id :=
        'c' || REPLACE(GEN_RANDOM_UUID()::TEXT, '-', '');

    INSERT INTO "support"."ticketcomment" (
        "id",
        "ticketId",
        "message",
        "commentBy",
        "commentType",
        "isInternal",
        "attachments",
        "createdAt",
        "updatedAt"
    )
    VALUES (
        v_comment_id,
        p_ticket_id,
        p_message,
        COALESCE(p_comment_by, p_customer_number),
        'USER',
        FALSE,
        p_attachments,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );

    UPDATE "support"."ticket"
    SET "updatedAt" = CURRENT_TIMESTAMP
    WHERE "id" = p_ticket_id;

    -- Return the created comment as normal rows.
    OPEN p_cursor FOR
    SELECT *
    FROM "support"."ticketcomment"
    WHERE "id" = v_comment_id;
END;
$$;

5.
-----------------------------------------------------------


CREATE OR REPLACE PROCEDURE "support"."sp_rate_ticket"(
    IN p_ticket_id VARCHAR(191),
    IN p_customer_number VARCHAR(191),
    IN p_rating INTEGER,
    IN p_feedback TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_ticket_status VARCHAR(191);
    v_existing_rating INTEGER;
    v_is_final BOOLEAN;
BEGIN
    IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
        RAISE EXCEPTION 'Rating must be between 1 and 5';
    END IF;

    -- Verify ticket ownership.
    SELECT
        t."status",
        t."rating"
    INTO
        v_ticket_status,
        v_existing_rating
    FROM "support"."ticket" AS t
    WHERE t."id" = p_ticket_id
      AND t."customer_number" = p_customer_number;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ticket not found';
    END IF;

    -- Check whether the ticket status is final/closed.
    SELECT s."isFinal"
    INTO v_is_final
    FROM "support"."ticketstatusconfig" AS s
    WHERE s."name" = v_ticket_status
      AND s."isActive" = TRUE
    LIMIT 1;

    IF COALESCE(v_is_final, FALSE) = FALSE THEN
        RAISE EXCEPTION 'Can only rate closed tickets';
    END IF;

    IF v_existing_rating IS NOT NULL THEN
        RAISE EXCEPTION 'Ticket has already been rated';
    END IF;

    -- Save the rating.
    UPDATE "support"."ticket"
    SET
        "rating" = p_rating,
        "ratingFeedback" = p_feedback,
        "ratedAt" = CURRENT_TIMESTAMP
    WHERE "id" = p_ticket_id
      AND "customer_number" = p_customer_number;

    -- Return the saved rating as normal rows.
    OPEN p_cursor FOR
    SELECT
        "id" AS ticket_id,
        "rating",
        "ratingFeedback" AS feedback,
        "ratedAt"
    FROM "support"."ticket"
    WHERE "id" = p_ticket_id;
END;
$$;

6.
-- SP Name: sp_generate_ticket_number
-- Function: generateTicketNumber
-- File: user.ticket.controller.js
-- Purpose: Generates a unique ticket number for the current day in format TKTYYMMDDXXXX.

CREATE OR REPLACE PROCEDURE "support"."sp_generate_ticket_number"(
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_sequence INTEGER;
    v_ticket_number VARCHAR(191);
BEGIN
    -- Count tickets created today.
    SELECT COUNT(*) + 1
    INTO v_sequence
    FROM "support"."ticket"
    WHERE "createdAt"::DATE = CURRENT_DATE;

    -- Generate number such as TKT2609290001.
    v_ticket_number :=
        'TKT'
        || TO_CHAR(CURRENT_DATE, 'YYMMDD')
        || LPAD(v_sequence::TEXT, 4, '0');

    -- Return the ticket number as a normal row.
    OPEN p_cursor FOR
    SELECT v_ticket_number AS "ticketNumber";
END;
$$;

7.
/* ============================================================
   SUPPORT PUBLIC HELPDESK PROCEDURES
   ============================================================

   PURPOSE:
   These procedures are used to expose public/helpdesk information
   such as:

   1. Help categories
   2. FAQs
   3. Help videos
   4. Ticket categories
   5. Ticket statuses

   WHY REFCURSOR?
   --------------
   These procedures return normal database rows through a cursor
   instead of returning JSONB.
 */



/* ============================================================
   1. GET PUBLIC HELP CATEGORIES
   ============================================================

   PURPOSE:
   Returns all public help categories.

   Example categories:
   - Account
   - Payments
   - Orders
   - KYC
   - Security

   WHY THIS PROCEDURE?
   -------------------
   The frontend/help center needs a list of available categories.

   It also returns:
   - Number of active FAQs in each category
   - Number of active videos in each category

   p_is_active:
   - TRUE  -> only active categories
   - FALSE -> only inactive categories
   - NULL  -> treated as TRUE

   ============================================================ */
7.

CREATE OR REPLACE PROCEDURE "support"."sp_get_public_categories"(
    IN p_is_active BOOLEAN,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN p_cursor FOR

    SELECT
        c.*,

        /* Count active FAQs belonging to this category */
        (
            SELECT COUNT(*)
            FROM "support"."helpfaq" f
            WHERE f."categoryId" = c."id"
              AND f."isActive" = TRUE
        ) AS "faqCount",

        /* Count active videos belonging to this category */
        (
            SELECT COUNT(*)
            FROM "content"."helpvideo" v
            WHERE v."categoryId" = c."id"
              AND v."isActive" = TRUE
        ) AS "videoCount"

    FROM "support"."helpcategory" c

    WHERE c."isActive" = COALESCE(p_is_active, TRUE)

    ORDER BY c."sortOrder" ASC;

END;
$$;

-- 8.

/* ============================================================
   2. GET ONE PUBLIC HELP CATEGORY
   ============================================================

   PURPOSE:
   Returns complete information for one help category.

   It includes:
   - Category information
   - FAQs belonging to the category
   - FAQ-related video
   - Videos belonging to the category

   WHY THIS PROCEDURE?
   -------------------
   When a user clicks a help category, the application needs
   all related information to display the category detail page.

   Example:

       User clicks "Payments"

       Category
          |
          +---- FAQ 1
          |       |
          |       +---- Video
          |
          +---- FAQ 2
          |
          +---- Video 1
          |
          +---- Video 2

   ============================================================ */

CREATE OR REPLACE PROCEDURE "content"."sp_get_public_category"(
    IN p_id VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN p_cursor FOR

    SELECT
        c."id" AS category_id,
        c."title",
        c."description",
        c."icon",
        c."sortOrder",
        c."isActive",

        /* FAQ information */
        f."id" AS faq_id,
        f."question",
        f."answer",
        f."sortOrder" AS faq_sort_order,

        /* Video attached to the FAQ */
        v."id" AS faq_video_id,
        v."title" AS faq_video_title,
        v."url" AS faq_video_url,
        v."thumbnailUrl" AS faq_video_thumbnail,

        /* Category video */
        cv."id" AS video_id,
        cv."title" AS video_title,
        cv."description" AS video_description,
        cv."url" AS video_url,
        cv."thumbnailUrl" AS video_thumbnail,
        cv."sortOrder" AS video_sort_order,
        cv."viewCount"

    FROM "support"."helpcategory" c

    /* Get active FAQs for the category */
    LEFT JOIN "support"."helpfaq" f
        ON f."categoryId" = c."id"
       AND f."isActive" = TRUE

    /* Get video attached to the FAQ */
    LEFT JOIN "content"."helpvideo" v
        ON v."id" = f."videoId"

    /* Get active videos directly belonging to category */
    LEFT JOIN "content"."helpvideo" cv
        ON cv."categoryId" = c."id"
       AND cv."isActive" = TRUE

    WHERE c."id" = p_id

    ORDER BY
        f."sortOrder",
        cv."sortOrder";

END;
$$;


/* ============================================================
   3. GET PUBLIC FAQs
   ============================================================

   PURPOSE:
   Returns FAQs with optional filtering.

   Supported filters:
   - Category
   - Published/active status
   - Search text

   WHY THIS PROCEDURE?
   -------------------
   The frontend may need:
   - All FAQs
   - FAQs from one category
   - Search results
   - Only active FAQs

   Instead of creating separate SQL queries for every case,
   one procedure handles all filters.

   ============================================================ */
9. 

CREATE OR REPLACE PROCEDURE "support"."sp_get_public_faqs"(
    IN p_category_id VARCHAR(191),
    IN p_is_published BOOLEAN,
    IN p_search TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN p_cursor FOR

    SELECT
        f.*,

        /* Category information */
        c."title" AS category_title,
        c."icon" AS category_icon,

        /* Related video information */
        v."title" AS video_title,
        v."url" AS video_url,
        v."thumbnailUrl" AS video_thumbnail

    FROM "support"."helpfaq" f

    /* FAQ must belong to a category */
    JOIN "support"."helpcategory" c
        ON c."id" = f."categoryId"

    /* Video is optional */
    LEFT JOIN "content"."helpvideo" v
        ON v."id" = f."videoId"

    WHERE
        /* NULL means TRUE */
        f."isActive" = COALESCE(p_is_published, TRUE)

        /* Category filter is optional */
        AND (
            p_category_id IS NULL
            OR f."categoryId" = p_category_id
        )

        /* Search question or answer */
        AND (
            p_search IS NULL
            OR f."question" ILIKE '%' || p_search || '%'
            OR f."answer" ILIKE '%' || p_search || '%'
        )

    ORDER BY f."sortOrder";

END;
$$;

10.

/* ============================================================
   4. GET ONE PUBLIC FAQ
   ============================================================

   PURPOSE:
   Returns complete information about a single FAQ.

   It returns:
   - FAQ information
   - Category information
   - Related video information

   WHY THIS PROCEDURE?
   -------------------
   When a user opens one FAQ, the frontend needs the FAQ
   together with its related category and video.

   ============================================================ */

CREATE OR REPLACE PROCEDURE "support"."sp_get_public_faq"(
    IN p_id VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN p_cursor FOR

    SELECT
        f.*,

        /* Convert category row into JSONB */
        to_jsonb(c) AS category,

        /* Convert video row into JSONB */
        to_jsonb(v) AS video

    FROM "support"."helpfaq" f

    LEFT JOIN "support"."helpcategory" c
        ON c."id" = f."categoryId"

    LEFT JOIN "content"."helpvideo" v
        ON v."id" = f."videoId"

    WHERE f."id" = p_id;

END;
$$;

select * from "support"."helpfaq"

11.
/* ============================================================
   5. SEARCH FAQs
   ============================================================

   PURPOSE:
   Searches active FAQs using a text query.

   WHY THIS PROCEDURE?
   -------------------
   The help center normally has a search box.

   Example:

       User searches:
       "password"

   The procedure searches:
       question
       answer

   Only active FAQs are returned.

   Maximum result:
       20 records

   WHY MINIMUM 2 CHARACTERS?
   --------------------------
   Searching with one character can generate a very large
   number of unnecessary database matches.

   ============================================================ */

CREATE OR REPLACE PROCEDURE "support"."sp_search_faqs"(
    IN p_query TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    /* Validate search input */
    IF p_query IS NULL
       OR LENGTH(p_query) < 2
    THEN

        RAISE EXCEPTION
            'Search query must be at least 2 characters';

    END IF;


    OPEN p_cursor FOR

    SELECT
        f."id",
        f."question",
        f."answer",
        f."categoryId",
        f."videoId",
        f."sortOrder",

        c."title" AS category_title,

        v."title" AS video_title,
        v."url" AS video_url

    FROM "support"."helpfaq" f

    JOIN "support"."helpcategory" c
        ON c."id" = f."categoryId"

    LEFT JOIN "content"."helpvideo" v
        ON v."id" = f."videoId"

    WHERE
        /* Search only active FAQs */
        f."isActive" = TRUE

        AND (
            f."question" ILIKE '%' || p_query || '%'
            OR f."answer" ILIKE '%' || p_query || '%'
        )

    ORDER BY f."sortOrder"

    /* Prevent too many search results */
    LIMIT 20;

END;
$$;



12.
/* ============================================================
   6. GET PUBLIC VIDEOS
   ============================================================

   PURPOSE:
   Returns help videos.

   Optional filters:
   - Category
   - Active status
   - Tags

   WHY THIS PROCEDURE?
   -------------------
   The help center can have many instructional videos.

   This procedure allows the frontend to retrieve videos
   according to category or tags.

   Example tags:

       "payment,refund,transaction"

   ============================================================ */

CREATE OR REPLACE PROCEDURE "content"."sp_get_public_videos"(
    IN p_category_id VARCHAR(191),
    IN p_is_active BOOLEAN,
    IN p_tags TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN p_cursor FOR

    SELECT
        v.*,

        c."title" AS category_title

    FROM "content"."helpvideo" v

    LEFT JOIN "support"."helpcategory" c
        ON c."id" = v."categoryId"

    WHERE

        /* Active filter */
        v."isActive" = COALESCE(p_is_active, TRUE)

        /* Optional category filter */
        AND (
            p_category_id IS NULL
            OR v."categoryId" = p_category_id
        )

        /* Optional tag filter */
        AND (
            p_tags IS NULL

            OR EXISTS (

                SELECT 1

                FROM jsonb_array_elements_text(
                    COALESCE(v."tags", '[]'::jsonb)
                ) x(tag)

                WHERE LOWER(x.tag)
                    = ANY(
                        string_to_array(
                            LOWER(REPLACE(p_tags, ' ', '')),
                            ','
                        )
                    )
            )
        )

    ORDER BY
        v."sortOrder",
        v."createdAt" DESC;

END;
$$;


13.
/* ============================================================
   7. GET ONE PUBLIC VIDEO
   ============================================================

   PURPOSE:
   Returns one video with its category and related FAQs.

   IMPORTANT:
   Every time this procedure is called, the video's viewCount
   is increased by 1.

   WHY THIS PROCEDURE?
   -------------------
   When a user opens/watches a help video, we need:

   - Video information
   - Category information
   - Related FAQs
   - Updated view count

   Keeping this operation together makes the operation
   consistent.

   ============================================================ */

CREATE OR REPLACE PROCEDURE "content"."sp_get_public_video"(
    IN p_id VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    /* Increase video view count */
    UPDATE "content"."helpvideo"

    SET "viewCount" = COALESCE("viewCount", 0) + 1

    WHERE "id" = p_id;


    OPEN p_cursor FOR

    SELECT
        v.*,

        /* Category information */
        to_jsonb(c) AS category,

        /* Related active FAQs */
        COALESCE(

            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', f."id",
                        'question', f."question"
                    )
                    ORDER BY f."sortOrder"
                )

                FROM "support"."helpfaq" f

                WHERE f."videoId" = v."id"
                  AND f."isActive" = TRUE
            ),

            '[]'::jsonb

        ) AS faqs

    FROM "content"."helpvideo" v

    LEFT JOIN "support"."helpcategory" c
        ON c."id" = v."categoryId"

    WHERE v."id" = p_id;

END;
$$;

14.
/* ============================================================
   8. GET VIDEOS BY TAGS
   ============================================================

   PURPOSE:
   Returns active videos matching one or more tags.

   Example:

       p_tags = 'payment,refund'

   WHY THIS PROCEDURE?
   -------------------
   This is useful when the frontend wants to show videos
   related to a particular topic.

   Example:

       Payment page
           |
           +-- payment video
           +-- refund video

   The procedure requires at least one tag.

   ============================================================ */

CREATE OR REPLACE PROCEDURE "content"."sp_get_videos_by_tags"(
    IN p_tags TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    /* Validate tags */
    IF p_tags IS NULL
       OR BTRIM(p_tags) = ''
    THEN

        RAISE EXCEPTION
            'Tags parameter is required';

    END IF;


    OPEN p_cursor FOR

    SELECT
        v.*,

        c."title" AS category_title

    FROM "content"."helpvideo" v

    LEFT JOIN "support"."helpcategory" c
        ON c."id" = v."categoryId"

    WHERE
        /* Only active videos */
        v."isActive" = TRUE

        AND EXISTS (

            SELECT 1

            FROM jsonb_array_elements_text(
                COALESCE(v."tags", '[]'::jsonb)
            ) x(tag)

            WHERE LOWER(x.tag)
                = ANY(
                    string_to_array(
                        LOWER(REPLACE(p_tags, ' ', '')),
                        ','
                    )
                )
        );

END;
$$;

15.
/* ============================================================
   9. GET TICKET CATEGORIES
   ============================================================

   PURPOSE:
   Returns active ticket categories and their active
   subcategories.

   Example:

       Account
          |
          +-- Login Problem
          +-- Password Problem
          +-- Profile Problem

       Payment
          |
          +-- Payment Failed
          +-- Refund
          +-- Transaction Issue

   WHY THIS PROCEDURE?
   -------------------
   When a user creates a support ticket, the frontend needs
   to display available categories and subcategories.

   The procedure returns the subcategories as JSONB so that
   the frontend can receive the category hierarchy together.

   ============================================================ */

DROP PROCEDURE IF EXISTS sp_get_ticket_categories(REFCURSOR);

CREATE OR REPLACE PROCEDURE "support"."sp_get_ticket_categories"(
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT
        c."id" AS category_id,
        c."name" AS category_name,
        c."description" AS category_description,
        c."icon" AS category_icon,
        c."attachmentRequired" AS category_attachment_required,
        c."sortOrder" AS category_sort_order,

        s."id" AS subcategory_id,
        s."name" AS subcategory_name,
        s."description" AS subcategory_description,
        s."attachmentRequired" AS subcategory_attachment_required,
        s."sortOrder" AS subcategory_sort_order

    FROM "support"."ticketcategoryconfig" AS c
    LEFT JOIN "support"."ticketsubcategory" AS s
        ON s."categoryId" = c."id"
       AND s."isActive" = TRUE

    WHERE c."isActive" = TRUE
    ORDER BY
        c."sortOrder" ASC,
        s."sortOrder" ASC;
END;
$$;

16.
/* ============================================================
   10. GET TICKET STATUSES
   ============================================================

   PURPOSE:
   Returns available ticket statuses.

   Example:

       OPEN
       IN_PROGRESS
       RESOLVED
       CLOSED

   p_status_type:
   - Allows the application to request statuses for a
     particular status type.
   - If NULL, USER is used as the default.

   WHY THIS PROCEDURE?
   -------------------
   The frontend needs to know which ticket statuses are
   available instead of hard-coding them inside Node.js.

   This also allows administrators to manage status
   configuration from the database.

   ============================================================ */

CREATE OR REPLACE PROCEDURE "support"."sp_get_ticket_statuses"(
    IN p_status_type VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN p_cursor FOR

    SELECT *

    FROM "support"."ticketstatusconfig"

    WHERE
        "isActive" = TRUE

        AND "statusType" = COALESCE(
            p_status_type,
            'USER'
        )

    ORDER BY "sortOrder";

END;
$$;

17.
-------------------------------------------------------------------------
-- this is sp from file admin.ticketConfig.controller.js file.

-- Procedure: sp_create_ticket_category
-- Purpose: Creates a new ticket category
-- Replaces: createTicketCategory in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketcategoryconfig

CREATE OR REPLACE PROCEDURE "support"."sp_create_ticket_category"(
    IN p_name VARCHAR,
    IN p_description TEXT DEFAULT NULL,
    IN p_icon VARCHAR DEFAULT NULL,
    IN p_attachment_required BOOLEAN DEFAULT FALSE,
    IN p_sort_order INTEGER DEFAULT 0,
    IN p_is_active BOOLEAN DEFAULT TRUE,
    INOUT ref REFCURSOR DEFAULT 'new_category_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id VARCHAR(191);
BEGIN
    -- Validate required category name
    IF p_name IS NULL OR BTRIM(p_name) = '' THEN
        RAISE EXCEPTION 'Name is required'
            USING ERRCODE = '23502';
    END IF;

    -- Generate a unique ID
    v_id :=
        'c' || REPLACE(GEN_RANDOM_UUID()::TEXT, '-', '');

    -- Create the ticket category
    INSERT INTO "support"."ticketcategoryconfig" (
        "id",
        "name",
        "description",
        "icon",
        "attachmentRequired",
        "sortOrder",
        "isActive",
        "createdAt",
        "updatedAt"
    )
    VALUES (
        v_id,
        p_name,
        p_description,
        p_icon,
        COALESCE(p_attachment_required, FALSE),
        COALESCE(p_sort_order, 0),
        COALESCE(p_is_active, TRUE),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );

    -- Return the created category
    OPEN ref FOR
    SELECT
        "id",
        "name",
        "description",
        "icon",
        "attachmentRequired",
        "sortOrder",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketcategoryconfig"
    WHERE "id" = v_id;
END;
$$;

18.
-- Procedure: sp_delete_ticket_category
-- Purpose: Deletes a ticket category
--          Deletion is blocked if tickets exist
-- Schema: support
-- Tables: "ticketcategoryconfig", "ticket"

CREATE OR REPLACE PROCEDURE "support"."sp_delete_ticket_category"(
    IN p_id VARCHAR,
    INOUT ref REFCURSOR DEFAULT 'delete_result_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
    v_ticket_count INTEGER;
BEGIN

    -- Check whether the category exists
    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticketcategoryconfig"
        WHERE "id" = p_id
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'Category not found'
            USING ERRCODE = 'P0002';
    END IF;


    -- Check whether tickets are using this category
    SELECT COUNT(*)
    INTO v_ticket_count
    FROM "support"."ticket"
    WHERE "categoryId" = p_id;

    IF v_ticket_count > 0 THEN
        RAISE EXCEPTION
            'Cannot delete category. It has % associated tickets.',
            v_ticket_count
            USING ERRCODE = '23503';
    END IF;


    -- Delete the category
    DELETE FROM "support"."ticketcategoryconfig"
    WHERE "id" = p_id;


    -- Return deletion result through cursor
    OPEN ref FOR
    SELECT
        p_id AS "id",
        'Category deleted successfully'::TEXT AS "message";

END;
$$;

19.
-- ============================================================
-- Procedure: sp_get_all_ticket_categories
-- Purpose:
--     Get ticket categories with ticket and subcategory counts.
--
-- subcategory_count:
--     Counts ALL subcategories, active and inactive.
--
-- p_include_inactive:
--     Controls which CATEGORIES are returned.
-- ============================================================

CREATE OR REPLACE PROCEDURE "support"."sp_get_all_ticket_categories"(
    IN p_search TEXT DEFAULT '',
    IN p_include_inactive BOOLEAN DEFAULT FALSE,
    INOUT ref REFCURSOR DEFAULT 'ticket_categories_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN ref FOR

    SELECT
        tc."id",
        tc."name",
        tc."description",
        tc."icon",
        tc."attachmentRequired",
        tc."sortOrder",
        tc."isActive",
        tc."createdAt",
        tc."updatedAt",

        COUNT(DISTINCT t."id") AS ticket_count,

        COUNT(DISTINCT sc."id") AS subcategory_count

    FROM "support"."ticketcategoryconfig" tc

    -- Count all tickets for the category
    LEFT JOIN "support"."ticket" t
        ON t."categoryId" = tc."id"

    -- Count ALL subcategories
    LEFT JOIN "support"."ticketsubcategory" sc
        ON sc."categoryId" = tc."id"

    WHERE
        (
            p_include_inactive = TRUE
            OR tc."isActive" = TRUE
        )

        AND
        (
            p_search IS NULL
            OR BTRIM(p_search) = ''
            OR tc."name" ILIKE '%' || p_search || '%'
            OR tc."description" ILIKE '%' || p_search || '%'
        )

    GROUP BY
        tc."id",
        tc."name",
        tc."description",
        tc."icon",
        tc."attachmentRequired",
        tc."sortOrder",
        tc."isActive",
        tc."createdAt",
        tc."updatedAt"

    ORDER BY
        tc."sortOrder" ASC;

END;
$$;

20.
-- ============================================================
-- Procedure: sp_get_ticket_category
-- Purpose:
--     Get one ticket category and ALL of its subcategories.
--
-- Important:
--     Both active and inactive subcategories are returned.
--     This matches:
--         orderBy: { sortOrder: "asc" }
-- ============================================================

CREATE OR REPLACE PROCEDURE "support"."sp_get_ticket_category"(
    IN p_id VARCHAR,
    INOUT ref REFCURSOR DEFAULT 'ticket_category_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN ref FOR

    SELECT
        tc."id" AS category_id,
        tc."name" AS category_name,
        tc."description" AS category_description,
        tc."icon" AS category_icon,
        tc."attachmentRequired" AS attachment_required,
        tc."sortOrder" AS category_sort_order,
        tc."isActive" AS category_is_active,
        tc."createdAt" AS category_created_at,
        tc."updatedAt" AS category_updated_at,
        sc."id" AS subcategory_id,
        sc."name" AS subcategory_name,
        sc."description" AS subcategory_description,
        sc."sortOrder" AS subcategory_sort_order,
        sc."isActive" AS subcategory_is_active,
        sc."createdAt" AS subcategory_created_at,
        sc."updatedAt" AS subcategory_updated_at

    FROM "support"."ticketcategoryconfig" tc

    LEFT JOIN "support"."ticketsubcategory" sc
        ON sc."categoryId" = tc."id"

    WHERE tc."id" = p_id

    ORDER BY
        sc."sortOrder" ASC;

END;
$$;
/*
BEGIN;

CALL "support"."sp_get_ticket_category"(
    'TC001',
    'ticket_category_cursor'
);

FETCH ALL FROM ticket_category_cursor;

COMMIT;
*/

21.
-- ============================================================
-- Procedure: sp_update_ticket_category
-- Purpose:
--     Partial update of a ticket category.
--
-- Important:
--     *_supplied flags distinguish:
--
--       parameter not supplied
--             from
--       parameter explicitly set to NULL
--
-- Example:
--     p_description_supplied = TRUE
--     p_description = NULL
--
--     => clears the description.
-- ============================================================

CREATE OR REPLACE PROCEDURE "support"."sp_update_ticket_category"(
    IN p_id VARCHAR,

    IN p_name VARCHAR DEFAULT NULL,

    IN p_description TEXT DEFAULT NULL,
    IN p_description_supplied BOOLEAN DEFAULT FALSE,

    IN p_icon VARCHAR DEFAULT NULL,
    IN p_icon_supplied BOOLEAN DEFAULT FALSE,

    IN p_attachment_required BOOLEAN DEFAULT NULL,
    IN p_attachment_required_supplied BOOLEAN DEFAULT FALSE,

    IN p_sort_order INTEGER DEFAULT NULL,
    IN p_sort_order_supplied BOOLEAN DEFAULT FALSE,

    IN p_is_active BOOLEAN DEFAULT NULL,
    IN p_is_active_supplied BOOLEAN DEFAULT FALSE,

    INOUT ref REFCURSOR DEFAULT 'updated_category_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN

    -- ========================================================
    -- 1. Check category exists
    -- ========================================================

    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticketcategoryconfig"
        WHERE "id" = p_id
    )
    INTO v_exists;


    IF NOT v_exists THEN

        RAISE EXCEPTION 'Category not found'
            USING ERRCODE = 'P0002';

    END IF;


    -- ========================================================
    -- 2. Update category
    -- ========================================================

    UPDATE "support"."ticketcategoryconfig"

    SET

        -- ----------------------------------------------------
        -- Name
        --
        -- Update only when:
        --   - value is not NULL
        --   - value is not empty/blank
        -- ----------------------------------------------------

        "name" =
            CASE
                WHEN p_name IS NOT NULL
                     AND BTRIM(p_name) <> ''
                THEN p_name
                ELSE "name"
            END,


        -- ----------------------------------------------------
        -- Description
        --
        -- If supplied:
        --     use supplied value, even NULL
        --
        -- If not supplied:
        --     keep existing value
        -- ----------------------------------------------------

        "description" =
            CASE
                WHEN p_description_supplied = TRUE
                THEN p_description
                ELSE "description"
            END,


        -- ----------------------------------------------------
        -- Icon
        -- ----------------------------------------------------

        "icon" =
            CASE
                WHEN p_icon_supplied = TRUE
                THEN p_icon
                ELSE "icon"
            END,


        -- ----------------------------------------------------
        -- Attachment Required
        -- ----------------------------------------------------

        "attachmentRequired" =
            CASE
                WHEN p_attachment_required_supplied = TRUE
                THEN p_attachment_required
                ELSE "attachmentRequired"
            END,


        -- ----------------------------------------------------
        -- Sort Order
        -- ----------------------------------------------------

        "sortOrder" =
            CASE
                WHEN p_sort_order_supplied = TRUE
                THEN p_sort_order
                ELSE "sortOrder"
            END,


        -- ----------------------------------------------------
        -- Active Status
        -- ----------------------------------------------------

        "isActive" =
            CASE
                WHEN p_is_active_supplied = TRUE
                THEN p_is_active
                ELSE "isActive"
            END,


        -- ----------------------------------------------------
        -- Updated timestamp
        -- ----------------------------------------------------

        "updatedAt" = CURRENT_TIMESTAMP

    WHERE "id" = p_id;


    -- ========================================================
    -- 3. Return updated category
    -- ========================================================

    OPEN ref FOR

    SELECT
        "id",
        "name",
        "description",
        "icon",
        "attachmentRequired",
        "sortOrder",
        "isActive",
        "createdAt",
        "updatedAt"

    FROM "support"."ticketcategoryconfig"

    WHERE "id" = p_id;

END;
$$;

22.
-- Procedure: sp_create_ticket_subcategory
-- Purpose:
--   Creates a new ticket subcategory under an existing category.
--
-- Returns:
--   The newly created subcategory as normal relational columns.
--
-- No JSONB is used.

-- ============================================================
-- Procedure: sp_create_ticket_subcategory
-- Purpose:
--   Creates a new ticket subcategory under an existing
--   ticket category.
--
-- ID format:
--   TSC001
--   TSC002
--   TSC003
--   ...
--
-- Returns:
--   Created subcategory as normal relational columns.
--   No JSONB is used.
-- ============================================================

CREATE OR REPLACE PROCEDURE "support"."sp_create_ticket_subcategory"(
    IN p_category_id VARCHAR,
    IN p_name VARCHAR,
    IN p_description TEXT DEFAULT NULL,
    IN p_sort_order INTEGER DEFAULT 0,
    IN p_is_active BOOLEAN DEFAULT TRUE,
    INOUT ref REFCURSOR DEFAULT 'new_subcategory_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_category_exists BOOLEAN;
    v_id VARCHAR(191);
BEGIN

    -- ========================================================
    -- 1. Validate required fields
    -- ========================================================

    IF p_category_id IS NULL
       OR BTRIM(p_category_id) = ''
       OR p_name IS NULL
       OR BTRIM(p_name) = '' THEN

        RAISE EXCEPTION 'Category ID and name are required'
            USING ERRCODE = '23502';

    END IF;


    -- ========================================================
    -- 2. Check whether parent category exists
    -- ========================================================

    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticketcategoryconfig"
        WHERE "id" = p_category_id
    )
    INTO v_category_exists;


    IF NOT v_category_exists THEN

        RAISE EXCEPTION 'Parent category not found'
            USING ERRCODE = 'P0002';

    END IF;


    -- ========================================================
    -- 3. Generate sequential subcategory ID
    --
    -- Existing:
    --   TSC001
    --   TSC002
    --   TSC006
    --
    -- New:
    --   TSC007
    -- ========================================================

    SELECT
        'TSC' || LPAD(
            (
                COALESCE(
                    MAX(
                        CAST(
                            SUBSTRING("id" FROM 4) AS INTEGER
                        )
                    ),
                    0
                ) + 1
            )::TEXT,
            3,
            '0'
        )
    INTO v_id
    FROM "support"."ticketsubcategory"
    WHERE "id" ~ '^TSC[0-9]+$';


    -- ========================================================
    -- 4. Insert new subcategory
    -- ========================================================

    INSERT INTO "support"."ticketsubcategory"
    (
        "id",
        "categoryId",
        "name",
        "description",
        "sortOrder",
        "isActive",
        "createdAt",
        "updatedAt"
    )
    VALUES
    (
        v_id,
        p_category_id,
        p_name,
        p_description,
        COALESCE(p_sort_order, 0),
        COALESCE(p_is_active, TRUE),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );


    -- ========================================================
    -- 5. Return created subcategory
    -- ========================================================

    OPEN ref FOR

    SELECT
        sc."id",
        sc."categoryId",
        sc."name",
        sc."description",
        sc."sortOrder",
        sc."isActive",
        sc."createdAt",
        sc."updatedAt",

        tc."id" AS category_id,
        tc."name" AS category_name

    FROM "support"."ticketsubcategory" sc

    JOIN "support"."ticketcategoryconfig" tc
        ON tc."id" = sc."categoryId"

    WHERE sc."id" = v_id;

END;
$$;

23.
-- select * from "support"."ticketsubcategory"

-- ============================================================
-- Procedure: sp_delete_ticket_subcategory
-- Purpose:
--   Deletes a ticket subcategory.
--
-- Delete is blocked when tickets are associated with the
-- subcategory.
--
-- Returns:
--   Deleted subcategory ID and success message.
--   No JSONB is used.
-- ============================================================

CREATE OR REPLACE PROCEDURE "support"."sp_delete_ticket_subcategory"(
    IN p_id VARCHAR,
    INOUT ref REFCURSOR DEFAULT 'delete_result_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
    v_ticket_count INTEGER;
BEGIN

    -- ========================================================
    -- 1. Check whether the subcategory exists
    -- ========================================================

    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticketsubcategory"
        WHERE "id" = p_id
    )
    INTO v_exists;


    IF NOT v_exists THEN

        RAISE EXCEPTION 'Subcategory not found'
            USING ERRCODE = 'P0002';

    END IF;


    -- ========================================================
    -- 2. Check whether tickets use this subcategory
    -- ========================================================

    SELECT COUNT(*)
    INTO v_ticket_count
    FROM "support"."ticket"
    WHERE "subcategoryId" = p_id;


    IF v_ticket_count > 0 THEN

        RAISE EXCEPTION
            'Cannot delete subcategory. It has % associated tickets.',
            v_ticket_count
            USING ERRCODE = '23503';

    END IF;


    -- ========================================================
    -- 3. Delete the subcategory
    -- ========================================================

    DELETE FROM "support"."ticketsubcategory"
    WHERE "id" = p_id;


    -- ========================================================
    -- 4. Return deletion result
    -- ========================================================

    OPEN ref FOR

    SELECT
        p_id AS "id",
        'Subcategory deleted successfully'::TEXT AS "message";

END;
$$;

24.
-- ============================================================
-- Procedure: sp_get_ticket_subcategories
-- Purpose:
--   Retrieves all subcategories for a given category.
--
-- p_include_inactive:
--   FALSE -> return only active subcategories
--   TRUE  -> return active and inactive subcategories
--
-- Returns:
--   Normal relational rows.
--   No JSONB is used.
-- ============================================================

CREATE OR REPLACE PROCEDURE "support"."sp_get_ticket_subcategories"(
    IN p_category_id VARCHAR,
    IN p_include_inactive BOOLEAN DEFAULT FALSE,
    INOUT ref REFCURSOR DEFAULT 'subcategories_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN ref FOR

    SELECT
        sc."id" AS subcategory_id,
        sc."categoryId" AS category_id,
        sc."name" AS subcategory_name,
        sc."description" AS subcategory_description,
        sc."sortOrder" AS subcategory_sort_order,
        sc."isActive" AS subcategory_is_active,
        sc."createdAt" AS subcategory_created_at,
        sc."updatedAt" AS subcategory_updated_at,

        tc."id" AS category_id,
        tc."name" AS category_name,

        COUNT(DISTINCT t."id") AS ticket_count

    FROM "support"."ticketsubcategory" sc

    JOIN "support"."ticketcategoryconfig" tc
        ON tc."id" = sc."categoryId"

    LEFT JOIN "support"."ticket" t
        ON t."subcategoryId" = sc."id"

    WHERE
        sc."categoryId" = p_category_id
        AND (
            p_include_inactive = TRUE
            OR sc."isActive" = TRUE
        )

    GROUP BY
        sc."id",
        sc."categoryId",
        sc."name",
        sc."description",
        sc."sortOrder",
        sc."isActive",
        sc."createdAt",
        sc."updatedAt",
        tc."id",
        tc."name"

    ORDER BY
        sc."sortOrder" ASC;

END;
$$;


25.
-- ============================================================
-- Procedure: sp_update_ticket_subcategory
-- Purpose:
--   Updates an existing ticket subcategory.
--
-- Supports partial updates.
--
-- Name:
--   NULL / empty / blank -> keep existing name
--
-- Description:
--   p_description_supplied = TRUE
--   allows description to be explicitly set to NULL.
--
-- No JSONB is returned.
-- ============================================================

CREATE OR REPLACE PROCEDURE "support"."sp_update_ticket_subcategory"(
    IN p_id VARCHAR,

    IN p_name VARCHAR DEFAULT NULL,

    IN p_description TEXT DEFAULT NULL,
    IN p_description_supplied BOOLEAN DEFAULT FALSE,

    IN p_sort_order INTEGER DEFAULT NULL,
    IN p_sort_order_supplied BOOLEAN DEFAULT FALSE,

    IN p_is_active BOOLEAN DEFAULT NULL,
    IN p_is_active_supplied BOOLEAN DEFAULT FALSE,

    INOUT ref REFCURSOR DEFAULT 'updated_subcategory_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN

    -- ========================================================
    -- 1. Check whether subcategory exists
    -- ========================================================

    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticketsubcategory"
        WHERE "id" = p_id
    )
    INTO v_exists;


    IF NOT v_exists THEN

        RAISE EXCEPTION 'Subcategory not found'
            USING ERRCODE = 'P0002';

    END IF;


    -- ========================================================
    -- 2. Update subcategory
    -- ========================================================

    UPDATE "support"."ticketsubcategory"

    SET

        -- Update name only when a non-empty value is supplied
        "name" =
            CASE
                WHEN p_name IS NOT NULL
                     AND BTRIM(p_name) <> ''
                THEN p_name
                ELSE "name"
            END,

        -- Allow description to be explicitly cleared
        "description" =
            CASE
                WHEN p_description_supplied = TRUE
                THEN p_description
                ELSE "description"
            END,

        -- Update sort order only when supplied
        "sortOrder" =
            CASE
                WHEN p_sort_order_supplied = TRUE
                THEN p_sort_order
                ELSE "sortOrder"
            END,

        -- Update active status only when supplied
        "isActive" =
            CASE
                WHEN p_is_active_supplied = TRUE
                THEN p_is_active
                ELSE "isActive"
            END,

        "updatedAt" = CURRENT_TIMESTAMP

    WHERE "id" = p_id;


    -- ========================================================
    -- 3. Return updated subcategory
    -- ========================================================

    OPEN ref FOR

    SELECT
        sc."id",
        sc."categoryId",
        sc."name",
        sc."description",
        sc."sortOrder",
        sc."isActive",
        sc."createdAt",
        sc."updatedAt",

        tc."id" AS category_id,
        tc."name" AS category_name

    FROM "support"."ticketsubcategory" sc

    JOIN "support"."ticketcategoryconfig" tc
        ON tc."id" = sc."categoryId"

    WHERE sc."id" = p_id;

END;
$$;

26
-- Procedure: sp_create_ticket_status
-- Purpose: Creates a new ticket status
-- Replaces: createTicketStatus in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketstatusconfig

CREATE OR REPLACE PROCEDURE "support"."sp_create_ticket_status"(
    IN p_name VARCHAR,
    IN p_label VARCHAR,
    IN p_description TEXT DEFAULT NULL,
    IN p_color VARCHAR DEFAULT '#6B7280',
    IN p_bg_color VARCHAR DEFAULT '#F3F4F6',
    IN p_icon VARCHAR DEFAULT NULL,
    IN p_status_type VARCHAR DEFAULT 'USER',
    IN p_sort_order INTEGER DEFAULT 0,
    IN p_is_default BOOLEAN DEFAULT FALSE,
    IN p_is_final BOOLEAN DEFAULT FALSE,
    IN p_is_active BOOLEAN DEFAULT TRUE,
    INOUT ref REFCURSOR DEFAULT 'new_status_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_name_exists BOOLEAN;
    v_id VARCHAR(191);
BEGIN

    -- 1. Validate required fields
    IF p_name IS NULL OR BTRIM(p_name) = ''
       OR p_label IS NULL OR BTRIM(p_label) = '' THEN

        RAISE EXCEPTION 'Name and label are required'
            USING ERRCODE = '23502';
    END IF;


    -- 2. Check duplicate status name
    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticketstatusconfig"
        WHERE "name" = p_name
    )
    INTO v_name_exists;

    IF v_name_exists THEN
        RAISE EXCEPTION 'Status with this name already exists'
            USING ERRCODE = '23505';
    END IF;


    -- 3. If this status is default,
    --    remove default from existing status
    IF p_is_default = TRUE THEN

        UPDATE "support"."ticketstatusconfig"
        SET "isDefault" = FALSE
        WHERE "statusType" = p_status_type
          AND "isDefault" = TRUE;

    END IF;


    -- 4. If this status is final,
    --    remove final from existing status
    IF p_is_final = TRUE THEN

        UPDATE "support"."ticketstatusconfig"
        SET "isFinal" = FALSE
        WHERE "statusType" = p_status_type
          AND "isFinal" = TRUE;

    END IF;


    -- 5. Generate status ID
    SELECT
        'TS' ||
        LPAD(
            (
                COALESCE(
                    MAX(
                        CAST(
                            SUBSTRING("id" FROM 3) AS INTEGER
                        )
                    ),
                    0
                ) + 1
            )::TEXT,
            3,
            '0'
        )
    INTO v_id
    FROM "support"."ticketstatusconfig"
    WHERE "id" ~ '^TS[0-9]+$';


    -- 6. Create status
    INSERT INTO "support"."ticketstatusconfig"
    (
        "id",
        "name",
        "label",
        "description",
        "color",
        "bgColor",
        "icon",
        "statusType",
        "sortOrder",
        "isDefault",
        "isFinal",
        "isActive",
        "createdAt",
        "updatedAt"
    )
    VALUES
    (
        v_id,
        p_name,
        p_label,
        p_description,
        p_color,
        p_bg_color,
        p_icon,
        p_status_type,
        COALESCE(p_sort_order, 0),
        COALESCE(p_is_default, FALSE),
        COALESCE(p_is_final, FALSE),
        COALESCE(p_is_active, TRUE),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );


    -- 7. Return created status
    OPEN ref FOR
    SELECT
        "id",
        "name",
        "label",
        "description",
        "color",
        "bgColor",
        "icon",
        "statusType",
        "sortOrder",
        "isDefault",
        "isFinal",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketstatusconfig"
    WHERE "id" = v_id;

END;
$$;

27.
-- Procedure: sp_delete_ticket_status
-- Purpose: Deletes a ticket status (blocked if it is the default status)
-- Replaces: deleteTicketStatus in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketstatusconfig

CREATE OR REPLACE PROCEDURE "support"."sp_delete_ticket_status"(
    IN p_id VARCHAR,
    INOUT ref REFCURSOR DEFAULT 'delete_result_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_existing RECORD;
BEGIN

    -- 1. Check whether status exists
    SELECT *
    INTO v_existing
    FROM "support"."ticketstatusconfig"
    WHERE "id" = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Status not found'
            USING ERRCODE = 'P0002';
    END IF;


    -- 2. Prevent deletion of default status
    IF v_existing."isDefault" = TRUE THEN
        RAISE EXCEPTION 'Cannot delete default status'
            USING ERRCODE = '23503';
    END IF;


    -- 3. Delete status
    DELETE FROM "support"."ticketstatusconfig"
    WHERE "id" = p_id;


    -- 4. Return deletion result
    OPEN ref FOR
    SELECT
        p_id AS "id",
        'Status deleted successfully'::TEXT AS "message";

END;
$$;

28
-- Procedure: sp_get_all_ticket_statuses
-- Purpose: Retrieves all ticket statuses with optional search and type filter
-- Replaces: getAllTicketStatuses in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketstatusconfig

CREATE OR REPLACE PROCEDURE "support"."sp_get_all_ticket_statuses"(
    IN p_search TEXT DEFAULT '',
    IN p_status_type VARCHAR DEFAULT '',
    IN p_include_inactive BOOLEAN DEFAULT FALSE,
    INOUT ref REFCURSOR DEFAULT 'ticket_statuses_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN ref FOR
    SELECT
        "id",
        "name",
        "label",
        "description",
        "color",
        "bgColor",
        "icon",
        "statusType",
        "sortOrder",
        "isDefault",
        "isFinal",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketstatusconfig"
    WHERE
        -- Same as:
        -- ...(includeInactive !== "true" && { isActive: true })
        (
            p_include_inactive = TRUE
            OR "isActive" = TRUE
        )

        -- Same as Prisma search OR
        AND (
            p_search IS NULL
            OR BTRIM(p_search) = ''
            OR "name" ILIKE '%' || p_search || '%'
            OR "label" ILIKE '%' || p_search || '%'
            OR "description" ILIKE '%' || p_search || '%'
        )

        -- Same as:
        -- ...(statusType && { statusType })
        AND (
            p_status_type IS NULL
            OR BTRIM(p_status_type) = ''
            OR "statusType" = p_status_type
        )

    ORDER BY "sortOrder" ASC;

END;
$$;

29.
-- Procedure: sp_get_ticket_status
-- Purpose: Retrieves a single ticket status by ID
-- Replaces: getTicketStatus in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketstatusconfig

CREATE OR REPLACE PROCEDURE "support"."sp_get_ticket_status"(
    IN p_id VARCHAR,
    INOUT ref REFCURSOR DEFAULT 'ticket_status_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN ref FOR
    SELECT
        "id",
        "name",
        "label",
        "description",
        "color",
        "bgColor",
        "icon",
        "statusType",
        "sortOrder",
        "isDefault",
        "isFinal",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketstatusconfig"
    WHERE "id" = p_id;

END;
$$;

30.
-- Procedure: sp_update_ticket_status
-- Purpose: Updates an existing ticket status
--          (handles isDefault/isFinal uniqueness)
-- Replaces: updateTicketStatus in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketstatusconfig

CREATE OR REPLACE PROCEDURE "support"."sp_update_ticket_status"(
    IN p_id VARCHAR,
    IN p_label VARCHAR DEFAULT NULL,
    IN p_description TEXT DEFAULT NULL,
    IN p_description_supplied BOOLEAN DEFAULT FALSE,
    IN p_color VARCHAR DEFAULT NULL,
    IN p_bg_color VARCHAR DEFAULT NULL,
    IN p_icon VARCHAR DEFAULT NULL,
    IN p_icon_supplied BOOLEAN DEFAULT FALSE,
    IN p_status_type VARCHAR DEFAULT NULL,
    IN p_sort_order INTEGER DEFAULT NULL,
    IN p_sort_order_supplied BOOLEAN DEFAULT FALSE,
    IN p_is_default BOOLEAN DEFAULT NULL,
    IN p_is_default_supplied BOOLEAN DEFAULT FALSE,
    IN p_is_final BOOLEAN DEFAULT NULL,
    IN p_is_final_supplied BOOLEAN DEFAULT FALSE,
    IN p_is_active BOOLEAN DEFAULT NULL,
    IN p_is_active_supplied BOOLEAN DEFAULT FALSE,
    INOUT ref REFCURSOR DEFAULT 'updated_status_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_existing RECORD;
    v_effective_type VARCHAR;
BEGIN

    -- 1. Check whether status exists
    SELECT *
    INTO v_existing
    FROM "support"."ticketstatusconfig"
    WHERE "id" = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Status not found'
            USING ERRCODE = 'P0002';
    END IF;


    -- 2. Determine effective status type
    v_effective_type := COALESCE(
        p_status_type,
        v_existing."statusType"
    );


    -- 3. If this status is being made default,
    --    remove default from other statuses
    IF p_is_default_supplied = TRUE
       AND p_is_default = TRUE
       AND v_existing."isDefault" IS NOT TRUE THEN

        UPDATE "support"."ticketstatusconfig"
        SET "isDefault" = FALSE
        WHERE "statusType" = v_effective_type
          AND "isDefault" = TRUE
          AND "id" <> p_id;

    END IF;


    -- 4. If this status is being made final,
    --    remove final from other statuses
    IF p_is_final_supplied = TRUE
       AND p_is_final = TRUE
       AND v_existing."isFinal" IS NOT TRUE THEN

        UPDATE "support"."ticketstatusconfig"
        SET "isFinal" = FALSE
        WHERE "statusType" = v_effective_type
          AND "isFinal" = TRUE
          AND "id" <> p_id;

    END IF;


    -- 5. Update status
    UPDATE "support"."ticketstatusconfig"
    SET
        "label" = CASE
            WHEN p_label IS NOT NULL
                 AND BTRIM(p_label) <> ''
            THEN p_label
            ELSE "label"
        END,

        "description" = CASE
            WHEN p_description_supplied = TRUE
            THEN p_description
            ELSE "description"
        END,

        "color" = CASE
            WHEN p_color IS NOT NULL
                 AND BTRIM(p_color) <> ''
            THEN p_color
            ELSE "color"
        END,

        "bgColor" = CASE
            WHEN p_bg_color IS NOT NULL
                 AND BTRIM(p_bg_color) <> ''
            THEN p_bg_color
            ELSE "bgColor"
        END,

        "icon" = CASE
            WHEN p_icon_supplied = TRUE
            THEN p_icon
            ELSE "icon"
        END,

        "statusType" = CASE
            WHEN p_status_type IS NOT NULL
                 AND BTRIM(p_status_type) <> ''
            THEN p_status_type
            ELSE "statusType"
        END,

        "sortOrder" = CASE
            WHEN p_sort_order_supplied = TRUE
            THEN p_sort_order
            ELSE "sortOrder"
        END,

        "isDefault" = CASE
            WHEN p_is_default_supplied = TRUE
            THEN p_is_default
            ELSE "isDefault"
        END,

        "isFinal" = CASE
            WHEN p_is_final_supplied = TRUE
            THEN p_is_final
            ELSE "isFinal"
        END,

        "isActive" = CASE
            WHEN p_is_active_supplied = TRUE
            THEN p_is_active
            ELSE "isActive"
        END,

        "updatedAt" = CURRENT_TIMESTAMP

    WHERE "id" = p_id;


    -- 6. Return updated status
    OPEN ref FOR
    SELECT
        "id",
        "name",
        "label",
        "description",
        "color",
        "bgColor",
        "icon",
        "statusType",
        "sortOrder",
        "isDefault",
        "isFinal",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketstatusconfig"
    WHERE "id" = p_id;

END;
$$;

31.
-- Procedure: sp_create_ticket_priority
-- Purpose: Creates a new ticket priority
-- Replaces: createTicketPriority in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketpriorityconfig

CREATE OR REPLACE PROCEDURE "support"."sp_create_ticket_priority"(
    IN p_name VARCHAR,
    IN p_label VARCHAR DEFAULT NULL,
    IN p_description TEXT DEFAULT NULL,
    IN p_color VARCHAR DEFAULT '#6B7280',
    IN p_bg_color VARCHAR DEFAULT '#F3F4F6',
    IN p_sort_order INTEGER DEFAULT 0,
    IN p_is_default BOOLEAN DEFAULT FALSE,
    IN p_is_active BOOLEAN DEFAULT TRUE,
    INOUT ref REFCURSOR DEFAULT 'new_priority_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_name_exists BOOLEAN;
    v_id VARCHAR(191);
BEGIN

    -- Check required name
    IF p_name IS NULL OR BTRIM(p_name) = '' THEN
        RAISE EXCEPTION 'Name is required'
            USING ERRCODE = '23502';
    END IF;


    -- Check duplicate name
    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticketpriorityconfig"
        WHERE "name" = p_name
    )
    INTO v_name_exists;

    IF v_name_exists THEN
        RAISE EXCEPTION 'Priority "%" already exists', p_name
            USING ERRCODE = '23505';
    END IF;


    -- If this priority is default,
    -- remove default from existing priority
    IF p_is_default = TRUE THEN
        UPDATE "support"."ticketpriorityconfig"
        SET "isDefault" = FALSE
        WHERE "isDefault" = TRUE;
    END IF;


    -- Generate ID: TP001, TP002, TP003...
    SELECT
        'TP' ||
        LPAD(
            (
                COALESCE(
                    MAX(
                        CAST(SUBSTRING("id" FROM 3) AS INTEGER)
                    ),
                    0
                ) + 1
            )::TEXT,
            3,
            '0'
        )
    INTO v_id
    FROM "support"."ticketpriorityconfig"
    WHERE "id" ~ '^TP[0-9]+$';


    -- Insert priority
    INSERT INTO "support"."ticketpriorityconfig"
    (
        "id",
        "name",
        "label",
        "description",
        "color",
        "bgColor",
        "sortOrder",
        "isDefault",
        "isActive",
        "createdAt",
        "updatedAt"
    )
    VALUES
    (
        v_id,
        p_name,
        p_label,
        p_description,
        p_color,
        p_bg_color,
        COALESCE(p_sort_order, 0),
        COALESCE(p_is_default, FALSE),
        COALESCE(p_is_active, TRUE),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );


    -- Return created priority
    OPEN ref FOR
    SELECT
        "id",
        "name",
        "label",
        "description",
        "color",
        "bgColor",
        "sortOrder",
        "isDefault",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketpriorityconfig"
    WHERE "id" = v_id;

END;
$$;

32.
-- Procedure: sp_delete_ticket_priority
-- Purpose: Deletes a ticket priority (blocked if it is the default priority)
-- Replaces: deleteTicketPriority in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketpriorityconfig

CREATE OR REPLACE PROCEDURE "support"."sp_delete_ticket_priority"(
    IN p_id VARCHAR,
    INOUT ref REFCURSOR DEFAULT 'delete_result_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_existing RECORD;
BEGIN

    -- Check whether priority exists
    SELECT *
    INTO v_existing
    FROM "support"."ticketpriorityconfig"
    WHERE "id" = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Priority not found'
            USING ERRCODE = 'P0002';
    END IF;


    -- Do not allow deletion of default priority
    IF v_existing."isDefault" = TRUE THEN
        RAISE EXCEPTION 'Cannot delete default priority'
            USING ERRCODE = '23503';
    END IF;


    -- Delete priority
    DELETE FROM "support"."ticketpriorityconfig"
    WHERE "id" = p_id;


    -- Return result
    OPEN ref FOR
    SELECT
        'Priority deleted successfully'::TEXT AS "message";

END;
$$;

33.
-- Procedure: sp_get_all_ticket_priorities
-- Purpose: Retrieves all ticket priorities with optional search
-- Replaces: getAllTicketPriorities in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketpriorityconfig

CREATE OR REPLACE PROCEDURE "support"."sp_get_all_ticket_priorities"(
    IN p_search TEXT DEFAULT '',
    IN p_include_inactive BOOLEAN DEFAULT FALSE,
    INOUT ref REFCURSOR DEFAULT 'ticket_priorities_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN ref FOR
    SELECT
        "id",
        "name",
        "label",
        "description",
        "color",
        "bgColor",
        "sortOrder",
        "isDefault",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketpriorityconfig"
    WHERE
        (
            p_include_inactive = TRUE
            OR "isActive" = TRUE
        )
        AND (
            p_search IS NULL
            OR BTRIM(p_search) = ''
            OR "name" ILIKE '%' || p_search || '%'
            OR "label" ILIKE '%' || p_search || '%'
            OR "description" ILIKE '%' || p_search || '%'
        )
    ORDER BY "sortOrder" ASC;

END;
$$;


34.
-- Procedure: sp_get_ticket_priority
-- Purpose: Retrieves a single ticket priority by ID
-- Replaces: getTicketPriority in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketpriorityconfig

CREATE OR REPLACE PROCEDURE "support"."sp_get_ticket_priority"(
    IN p_id VARCHAR,
    INOUT ref REFCURSOR DEFAULT 'ticket_priority_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN ref FOR
    SELECT
        "id",
        "name",
        "label",
        "description",
        "color",
        "bgColor",
        "sortOrder",
        "isDefault",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketpriorityconfig"
    WHERE "id" = p_id;
END;
$$;

35.
-- Procedure: sp_update_ticket_priority
-- Purpose: Updates an existing ticket priority
-- Replaces: updateTicketPriority in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketpriorityconfig

CREATE OR REPLACE PROCEDURE "support"."sp_update_ticket_priority"(
    IN p_id VARCHAR,
    IN p_label VARCHAR DEFAULT NULL,
    IN p_description TEXT DEFAULT NULL,
    IN p_description_supplied BOOLEAN DEFAULT FALSE,
    IN p_color VARCHAR DEFAULT NULL,
    IN p_bg_color VARCHAR DEFAULT NULL,
    IN p_sort_order INTEGER DEFAULT NULL,
    IN p_sort_order_supplied BOOLEAN DEFAULT FALSE,
    IN p_is_default BOOLEAN DEFAULT NULL,
    IN p_is_default_supplied BOOLEAN DEFAULT FALSE,
    IN p_is_active BOOLEAN DEFAULT NULL,
    IN p_is_active_supplied BOOLEAN DEFAULT FALSE,
    INOUT ref REFCURSOR DEFAULT 'updated_priority_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_existing RECORD;
BEGIN

    -- Check whether priority exists
    SELECT *
    INTO v_existing
    FROM "support"."ticketpriorityconfig"
    WHERE "id" = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Priority not found'
            USING ERRCODE = 'P0002';
    END IF;


    -- If this priority is being made default,
    -- remove default from all other priorities
    IF p_is_default_supplied = TRUE
       AND p_is_default = TRUE
       AND v_existing."isDefault" IS NOT TRUE
    THEN
        UPDATE "support"."ticketpriorityconfig"
        SET "isDefault" = FALSE
        WHERE "isDefault" = TRUE
          AND "id" <> p_id;
    END IF;


    -- Update priority
    UPDATE "support"."ticketpriorityconfig"
    SET
        "label" = CASE
            WHEN p_label IS NOT NULL
                 AND BTRIM(p_label) <> ''
            THEN p_label
            ELSE "label"
        END,

        "description" = CASE
            WHEN p_description_supplied = TRUE
            THEN p_description
            ELSE "description"
        END,

        "color" = CASE
            WHEN p_color IS NOT NULL
                 AND BTRIM(p_color) <> ''
            THEN p_color
            ELSE "color"
        END,

        "bgColor" = CASE
            WHEN p_bg_color IS NOT NULL
                 AND BTRIM(p_bg_color) <> ''
            THEN p_bg_color
            ELSE "bgColor"
        END,

        "sortOrder" = CASE
            WHEN p_sort_order_supplied = TRUE
            THEN p_sort_order
            ELSE "sortOrder"
        END,

        "isDefault" = CASE
            WHEN p_is_default_supplied = TRUE
            THEN p_is_default
            ELSE "isDefault"
        END,

        "isActive" = CASE
            WHEN p_is_active_supplied = TRUE
            THEN p_is_active
            ELSE "isActive"
        END,

        "updatedAt" = CURRENT_TIMESTAMP

    WHERE "id" = p_id;


    -- Return updated priority
    OPEN ref FOR
    SELECT
        "id",
        "name",
        "label",
        "description",
        "color",
        "bgColor",
        "sortOrder",
        "isDefault",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketpriorityconfig"
    WHERE "id" = p_id;

END;
$$;

36.
-- Procedure: sp_create_ticket_assignee
-- Purpose: Creates a new ticket assignee
-- Replaces: createTicketAssignee in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketassignee

CREATE OR REPLACE PROCEDURE "support"."sp_create_ticket_assignee"(
    IN p_name VARCHAR,
    IN p_email VARCHAR DEFAULT NULL,
    IN p_role VARCHAR DEFAULT NULL,
    IN p_department VARCHAR DEFAULT NULL,
    IN p_sort_order INTEGER DEFAULT 0,
    IN p_is_active BOOLEAN DEFAULT TRUE,
    INOUT ref REFCURSOR DEFAULT 'new_assignee_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id VARCHAR(191);
BEGIN

    -- Validate name
    IF p_name IS NULL OR BTRIM(p_name) = '' THEN
        RAISE EXCEPTION 'Name is required'
            USING ERRCODE = '23502';
    END IF;


    -- Generate assignee ID
    SELECT
        'TA' ||
        LPAD(
            (
                COALESCE(
                    MAX(
                        CAST(
                            SUBSTRING("id" FROM 3) AS INTEGER
                        )
                    ),
                    0
                ) + 1
            )::TEXT,
            3,
            '0'
        )
    INTO v_id
    FROM "support"."ticketassignee"
    WHERE "id" ~ '^TA[0-9]+$';


    -- Insert assignee
    INSERT INTO "support"."ticketassignee"
    (
        "id",
        "name",
        "email",
        "role",
        "department",
        "sortOrder",
        "isActive",
        "createdAt",
        "updatedAt"
    )
    VALUES
    (
        v_id,
        p_name,
        p_email,
        p_role,
        p_department,
        COALESCE(p_sort_order, 0),
        COALESCE(p_is_active, TRUE),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );


    -- Return created assignee
    OPEN ref FOR
    SELECT
        "id",
        "name",
        "email",
        "role",
        "department",
        "sortOrder",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketassignee"
    WHERE "id" = v_id;

END;
$$;

37.
-- Procedure: sp_delete_ticket_assignee
-- Purpose: Deletes a ticket assignee
-- Replaces: deleteTicketAssignee in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketassignee

CREATE OR REPLACE PROCEDURE "support"."sp_delete_ticket_assignee"(
    IN p_id VARCHAR,
    INOUT ref REFCURSOR DEFAULT 'delete_result_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN

    -- Check whether assignee exists
    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticketassignee"
        WHERE "id" = p_id
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'Assignee not found'
            USING ERRCODE = 'P0002';
    END IF;


    -- Delete assignee
    DELETE FROM "support"."ticketassignee"
    WHERE "id" = p_id;


    -- Return delete result
    OPEN ref FOR
    SELECT
        p_id AS "id",
        'Assignee deleted successfully'::TEXT AS "message";

END;
$$;

38.
-- Procedure: sp_get_all_ticket_assignees
-- Purpose: Retrieves all ticket assignees with ticket counts
-- Replaces: getAllTicketAssignees in admin.ticketConfig.controller.js
-- Schema: support
-- Tables: ticketassignee, ticket

CREATE OR REPLACE PROCEDURE "support"."sp_get_all_ticket_assignees"(
    IN p_search TEXT DEFAULT '',
    IN p_include_inactive BOOLEAN DEFAULT FALSE,
    INOUT ref REFCURSOR DEFAULT 'ticket_assignees_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_count
    FROM "support"."ticketassignee" ta
    WHERE
        (
            p_include_inactive = TRUE
            OR ta."isActive" = TRUE
        )
        AND
        (
            p_search IS NULL
            OR BTRIM(p_search) = ''
            OR ta."name" ILIKE '%' || p_search || '%'
            OR ta."email" ILIKE '%' || p_search || '%'
            OR ta."role" ILIKE '%' || p_search || '%'
        );


    IF v_count = 0 THEN

        OPEN ref FOR
        SELECT
            'No assignees found'::TEXT AS "message";

    ELSE

        OPEN ref FOR
        SELECT
            ta."id",
            ta."name",
            ta."email",
            ta."role",
            ta."department",
            ta."sortOrder",
            ta."isActive",
            ta."createdAt",
            ta."updatedAt",
            COUNT(DISTINCT t."id") AS ticket_count

        FROM "support"."ticketassignee" ta

        LEFT JOIN "support"."ticket" t
            ON t."assignedTo" = ta."id"

        WHERE
            (
                p_include_inactive = TRUE
                OR ta."isActive" = TRUE
            )
            AND
            (
                p_search IS NULL
                OR BTRIM(p_search) = ''
                OR ta."name" ILIKE '%' || p_search || '%'
                OR ta."email" ILIKE '%' || p_search || '%'
                OR ta."role" ILIKE '%' || p_search || '%'
            )

        GROUP BY
            ta."id",
            ta."name",
            ta."email",
            ta."role",
            ta."department",
            ta."sortOrder",
            ta."isActive",
            ta."createdAt",
            ta."updatedAt"

        ORDER BY ta."sortOrder" ASC;

    END IF;

END;
$$;

39.
-- Procedure: sp_get_ticket_assignee
-- Purpose: Retrieves a single ticket assignee by ID
-- Replaces: getTicketAssignee in admin.ticketConfig.controller.js
-- Schema: support
-- Tables: ticketassignee, ticket

CREATE OR REPLACE PROCEDURE "support"."sp_get_ticket_assignee"(
    IN p_id VARCHAR,
    INOUT ref REFCURSOR DEFAULT 'ticket_assignee_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN

    -- Check whether assignee exists
    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticketassignee"
        WHERE "id" = p_id
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'Assignee not found'
            USING ERRCODE = 'P0002';
    END IF;


    -- Return assignee with ticket count
    OPEN ref FOR
    SELECT
        ta."id",
        ta."name",
        ta."email",
        ta."role",
        ta."department",
        ta."sortOrder",
        ta."isActive",
        ta."createdAt",
        ta."updatedAt",
        COUNT(DISTINCT t."id") AS ticket_count
    FROM "support"."ticketassignee" ta
    LEFT JOIN "support"."ticket" t
        ON t."assignedTo" = ta."id"
    WHERE ta."id" = p_id
    GROUP BY
        ta."id",
        ta."name",
        ta."email",
        ta."role",
        ta."department",
        ta."sortOrder",
        ta."isActive",
        ta."createdAt",
        ta."updatedAt";

END;
$$;

40
-- Procedure: sp_update_ticket_assignee
-- Purpose: Updates an existing ticket assignee (partial update)
-- Replaces: updateTicketAssignee in admin.ticketConfig.controller.js
-- Schema: support
-- Table: ticketassignee

CREATE OR REPLACE PROCEDURE "support"."sp_update_ticket_assignee"(
    IN p_id VARCHAR,
    IN p_name VARCHAR DEFAULT NULL,
    IN p_email VARCHAR DEFAULT NULL,
    IN p_email_supplied BOOLEAN DEFAULT FALSE,
    IN p_role VARCHAR DEFAULT NULL,
    IN p_role_supplied BOOLEAN DEFAULT FALSE,
    IN p_department VARCHAR DEFAULT NULL,
    IN p_department_supplied BOOLEAN DEFAULT FALSE,
    IN p_sort_order INTEGER DEFAULT NULL,
    IN p_sort_order_supplied BOOLEAN DEFAULT FALSE,
    IN p_is_active BOOLEAN DEFAULT NULL,
    IN p_is_active_supplied BOOLEAN DEFAULT FALSE,
    INOUT ref REFCURSOR DEFAULT 'updated_assignee_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN

    -- Check whether assignee exists
    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticketassignee"
        WHERE "id" = p_id
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'Assignee not found'
            USING ERRCODE = 'P0002';
    END IF;


    -- Update assignee
    UPDATE "support"."ticketassignee"
    SET
        "name" = CASE
            WHEN p_name IS NOT NULL
                 AND BTRIM(p_name) <> ''
            THEN p_name
            ELSE "name"
        END,

        "email" = CASE
            WHEN p_email_supplied = TRUE
            THEN p_email
            ELSE "email"
        END,

        "role" = CASE
            WHEN p_role_supplied = TRUE
            THEN p_role
            ELSE "role"
        END,

        "department" = CASE
            WHEN p_department_supplied = TRUE
            THEN p_department
            ELSE "department"
        END,

        "sortOrder" = CASE
            WHEN p_sort_order_supplied = TRUE
            THEN p_sort_order
            ELSE "sortOrder"
        END,

        "isActive" = CASE
            WHEN p_is_active_supplied = TRUE
            THEN p_is_active
            ELSE "isActive"
        END,

        "updatedAt" = CURRENT_TIMESTAMP

    WHERE "id" = p_id;


    -- Return updated assignee
    OPEN ref FOR
    SELECT
        "id",
        "name",
        "email",
        "role",
        "department",
        "sortOrder",
        "isActive",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketassignee"
    WHERE "id" = p_id;

END;
$$;

41.
-- Purpose:
-- Retrieves all tickets for the admin panel with pagination,
-- filtering, searching, related user/category/subcategory/assignee details,
-- status and priority information, and total ticket count.

CREATE OR REPLACE PROCEDURE "support"."sp_admin_get_all_tickets"(
    IN p_page INTEGER,
    IN p_limit INTEGER,
    IN p_status VARCHAR(191),
    IN p_priority VARCHAR(191),
    IN p_category_id VARCHAR(191),
    IN p_search TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_page INTEGER;
    v_limit INTEGER;
    v_offset INTEGER;
    v_total BIGINT;
BEGIN
    v_page := GREATEST(COALESCE(p_page, 1), 1);
    v_limit := GREATEST(COALESCE(p_limit, 20), 1);
    v_offset := (v_page - 1) * v_limit;

    SELECT COUNT(*)
    INTO v_total
    FROM "support"."ticket" t
    WHERE
        (
            p_status IS NULL
            OR BTRIM(p_status) = ''
            OR t."status" = UPPER(p_status)
        )
        AND (
            p_priority IS NULL
            OR BTRIM(p_priority) = ''
            OR t."priority"::TEXT = UPPER(p_priority)
        )
        AND (
            p_category_id IS NULL
            OR BTRIM(p_category_id) = ''
            OR t."categoryId" = p_category_id
        )
        AND (
            p_search IS NULL
            OR BTRIM(p_search) = ''
            OR t."ticketNumber" ILIKE '%' || p_search || '%'
            OR t."subject" ILIKE '%' || p_search || '%'
            OR t."description" ILIKE '%' || p_search || '%'
            OR t."customer_number" ILIKE '%' || p_search || '%'
        );

    OPEN p_cursor FOR
    SELECT
        t.*,

        v_total AS total_count,
        v_page AS page,
        v_limit AS page_limit,

        u."id" AS user_id,
        u."email" AS user_email,
        u."first_name",
        u."last_name",

        c."name" AS category_name,
        sc."name" AS subcategory_name,

        a."name" AS assignee_name,
        a."email" AS assignee_email,

        st."label" AS status_label,
        st."color" AS status_color,
        st."bgColor" AS status_bg_color,

        pr."label" AS priority_label,
        pr."color" AS priority_color,
        pr."bgColor" AS priority_bg_color,

        (
            SELECT COUNT(*)
            FROM "support"."ticketcomment" tc
            WHERE tc."ticketId" = t."id"
        ) AS comment_count

    FROM "support"."ticket" t

    LEFT JOIN "user"."user" u
        ON u."customer_number" = t."customer_number"

    LEFT JOIN "support"."ticketcategoryconfig" c
        ON c."id" = t."categoryId"

    LEFT JOIN "support"."ticketsubcategory" sc
        ON sc."id" = t."subcategoryId"

    LEFT JOIN "support"."ticketassignee" a
        ON a."id" = t."assignedTo"

    LEFT JOIN "support"."ticketstatusconfig" st
        ON st."name" = t."status"

    LEFT JOIN "support"."ticketpriorityconfig" pr
        ON pr."name" = t."priority"::TEXT

    WHERE
        (
            p_status IS NULL
            OR BTRIM(p_status) = ''
            OR t."status" = UPPER(p_status)
        )
        AND (
            p_priority IS NULL
            OR BTRIM(p_priority) = ''
            OR t."priority"::TEXT = UPPER(p_priority)
        )
        AND (
            p_category_id IS NULL
            OR BTRIM(p_category_id) = ''
            OR t."categoryId" = p_category_id
        )
        AND (
            p_search IS NULL
            OR BTRIM(p_search) = ''
            OR t."ticketNumber" ILIKE '%' || p_search || '%'
            OR t."subject" ILIKE '%' || p_search || '%'
            OR t."description" ILIKE '%' || p_search || '%'
            OR t."customer_number" ILIKE '%' || p_search || '%'
        )

    ORDER BY t."createdAt" DESC
    OFFSET v_offset
    LIMIT v_limit;

END;
$$;


42.
-- Purpose:
-- Retrieves complete ticket details for an admin,
-- including ticket, user, category, subcategory, assignee,
-- status, priority, and ticket comment information.

CREATE OR REPLACE PROCEDURE "support"."sp_admin_get_ticket_details"(
    IN p_ticket_id VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN

    -- Check whether ticket exists
    SELECT EXISTS (
        SELECT 1
        FROM "support"."ticket"
        WHERE "id" = p_ticket_id
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'Ticket not found'
            USING ERRCODE = 'P0002';
    END IF;

    -- Get ticket details
    OPEN p_cursor FOR
    SELECT
        -- Ticket
        t.*,

        -- User
        u."id" AS user_id,
        u."email" AS user_email,
        u."first_name",
        u."last_name",
        u."customer_number",
        u."phone_number",

        -- Category
        c."name" AS category_name,

        -- Subcategory
        sc."name" AS subcategory_name,

        -- Assignee
        a."name" AS assignee_name,
        a."email" AS assignee_email,

        -- Status
        st."label" AS status_label,
        st."color" AS status_color,
        st."bgColor" AS status_bg_color,

        -- Priority
        pr."label" AS priority_label,
        pr."color" AS priority_color,
        pr."bgColor" AS priority_bg_color,

        -- Comment
        cm."id" AS comment_id,
        cm."message" AS comment_message,
        cm."commentBy",
        cm."commentType",
        cm."isInternal",
        cm."attachments" AS comment_attachments,
        cm."createdAt" AS comment_created_at,
        cm."updatedAt" AS comment_updated_at

    FROM "support"."ticket" t

    LEFT JOIN "user"."user" u
        ON u."customer_number" = t."customer_number"

    LEFT JOIN "support"."ticketcategoryconfig" c
        ON c."id" = t."categoryId"

    LEFT JOIN "support"."ticketsubcategory" sc
        ON sc."id" = t."subcategoryId"

    LEFT JOIN "support"."ticketassignee" a
        ON a."id" = t."assignedTo"

    LEFT JOIN "support"."ticketstatusconfig" st
        ON st."name" = t."status"

    LEFT JOIN "support"."ticketpriorityconfig" pr
        ON pr."name" = t."priority"::TEXT

    LEFT JOIN "support"."ticketcomment" cm
        ON cm."ticketId" = t."id"

    WHERE t."id" = p_ticket_id

    ORDER BY cm."createdAt" ASC;

END;
$$;


43.
-- p_status, p_priority, p_assigned_to, and p_resolution need to distinguish not supplied from NULL.
-- The controller checks the old status and new status configuration.
-- Reopening clears both closedAt and resolvedAt.
-- A final status sets closedAt.
-- resolvedAt is set when resolving, but should not unnecessarily be overwritten.
-- Email notifications belong in the application/service layer, not in this PostgreSQL procedure.
-- The procedure should return the updated ticket.


-- Purpose:
-- Updates an admin ticket's status, priority, assignee, and resolution.
-- Handles final, resolving, and reopening status transitions.
-- Updates resolvedAt and closedAt according to the new status.
-- Returns the updated ticket record.

CREATE OR REPLACE PROCEDURE "support"."sp_admin_update_ticket"(
    IN p_ticket_id VARCHAR(191),

    IN p_status VARCHAR(191),

    IN p_priority VARCHAR(191),

    IN p_assigned_to VARCHAR(191),

    IN p_resolution TEXT,

    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_status VARCHAR(191);
    v_old_closed TIMESTAMP;
    v_old_resolved TIMESTAMP;

    v_new_status VARCHAR(191);

    v_new_final BOOLEAN := FALSE;
    v_old_final BOOLEAN := FALSE;

    v_is_reopen BOOLEAN := FALSE;
    v_is_resolving BOOLEAN := FALSE;

    v_exists BOOLEAN;
BEGIN

    ----------------------------------------------------------------
    -- Check whether ticket exists and get current values
    ----------------------------------------------------------------

    SELECT
        "status",
        "closedAt",
        "resolvedAt"
    INTO
        v_old_status,
        v_old_closed,
        v_old_resolved
    FROM "support"."ticket"
    WHERE "id" = p_ticket_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ticket not found'
            USING ERRCODE = 'P0002';
    END IF;


    ----------------------------------------------------------------
    -- Determine new status
    ----------------------------------------------------------------

    v_new_status :=
        CASE
            WHEN p_status IS NOT NULL
                 AND BTRIM(p_status) <> ''
            THEN UPPER(p_status)
            ELSE v_old_status
        END;


    ----------------------------------------------------------------
    -- Get new status configuration
    ----------------------------------------------------------------

    SELECT COALESCE("isFinal", FALSE)
    INTO v_new_final
    FROM "support"."ticketstatusconfig"
    WHERE "name" = v_new_status
      AND "isActive" = TRUE
    LIMIT 1;


    ----------------------------------------------------------------
    -- Get old status configuration
    ----------------------------------------------------------------

    SELECT COALESCE("isFinal", FALSE)
    INTO v_old_final
    FROM "support"."ticketstatusconfig"
    WHERE "name" = v_old_status
      AND "isActive" = TRUE
    LIMIT 1;


    ----------------------------------------------------------------
    -- Check reopening status
    ----------------------------------------------------------------

    v_is_reopen :=
        (
            v_old_final = TRUE
            AND v_new_final = FALSE
        )
        OR
        v_new_status LIKE '%REOPEN%';


    ----------------------------------------------------------------
    -- Check resolving status
    ----------------------------------------------------------------

    v_is_resolving :=
        v_new_status LIKE '%RESOLV%';


    ----------------------------------------------------------------
    -- Update "support"."ticket"
    ----------------------------------------------------------------

    UPDATE "support"."ticket"
    SET

        ----------------------------------------------------------------
        -- Status
        ----------------------------------------------------------------
        "status" =
            CASE
                WHEN p_status IS NOT NULL
                     AND BTRIM(p_status) <> ''
                THEN v_new_status
                ELSE "status"
            END,


        ----------------------------------------------------------------
        -- Priority
        ----------------------------------------------------------------
        "priority" =
            CASE
                WHEN p_priority IS NOT NULL
                     AND BTRIM(p_priority) <> ''
                THEN UPPER(p_priority)::"enum_13"
                ELSE "priority"
            END,


        ----------------------------------------------------------------
        -- Assignee
        ----------------------------------------------------------------
        "assignedTo" =
            CASE
                WHEN p_assigned_to IS NOT NULL
                THEN NULLIF(BTRIM(p_assigned_to), '')
                ELSE "assignedTo"
            END,


        ----------------------------------------------------------------
        -- Resolution
        ----------------------------------------------------------------
        "resolution" =
            CASE
                WHEN p_resolution IS NOT NULL
                THEN p_resolution
                ELSE "resolution"
            END,


        ----------------------------------------------------------------
        -- resolvedAt
        ----------------------------------------------------------------
        "resolvedAt" =
            CASE

                -- Reopening ticket
                WHEN v_is_reopen = TRUE
                THEN NULL

                -- Final status: stamp resolvedAt only once
                WHEN v_new_final = TRUE
                     AND v_old_resolved IS NULL
                THEN CURRENT_TIMESTAMP

                -- Resolving status
                WHEN v_is_resolving = TRUE
                     AND v_old_resolved IS NULL
                THEN CURRENT_TIMESTAMP

                ELSE "resolvedAt"

            END,


        ----------------------------------------------------------------
        -- closedAt
        ----------------------------------------------------------------
        "closedAt" =
            CASE

                -- Reopening ticket
                WHEN v_is_reopen = TRUE
                THEN NULL

                -- Final status
                WHEN v_new_final = TRUE
                THEN CURRENT_TIMESTAMP

                ELSE "closedAt"

            END,


        ----------------------------------------------------------------
        -- Updated timestamp
        ----------------------------------------------------------------
        "updatedAt" = CURRENT_TIMESTAMP

    WHERE "id" = p_ticket_id;


    ----------------------------------------------------------------
    -- Return updated ticket
    ----------------------------------------------------------------

    OPEN p_cursor FOR

    SELECT *
    FROM "support"."ticket"
    WHERE "id" = p_ticket_id;

END;
$$;

44.
-- Purpose:
-- Adds an admin comment to an existing ticket.
-- Creates the comment record, sets firstResponseAt when this is
-- the first response, and changes an OPEN ticket to IN_PROGRESS
-- when the comment is not internal.
-- Returns the newly created comment.

CREATE OR REPLACE PROCEDURE "support"."sp_admin_add_comment"(
    IN p_ticket_id VARCHAR(191),
    IN p_message TEXT,
    IN p_admin_email VARCHAR(191),
    IN p_is_internal BOOLEAN,
    IN p_attachments JSONB,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id VARCHAR(191);
    v_status VARCHAR(191);
    v_first_response TIMESTAMP;
    v_is_internal BOOLEAN;
BEGIN

    ------------------------------------------------------------
    -- Validate message
    ------------------------------------------------------------

    IF p_message IS NULL OR BTRIM(p_message) = '' THEN
        RAISE EXCEPTION 'Comment message is required'
            USING ERRCODE = '23502';
    END IF;


    ------------------------------------------------------------
    -- Check ticket and get current values
    ------------------------------------------------------------

    SELECT
        "status",
        "firstResponseAt"
    INTO
        v_status,
        v_first_response
    FROM "support"."ticket"
    WHERE "id" = p_ticket_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ticket not found'
            USING ERRCODE = 'P0002';
    END IF;


    ------------------------------------------------------------
    -- Normalize internal flag
    ------------------------------------------------------------

    v_is_internal := COALESCE(p_is_internal, FALSE);


    ------------------------------------------------------------
    -- Generate comment ID
    ------------------------------------------------------------

    v_id :=
        'c' ||
        REPLACE(
            GEN_RANDOM_UUID()::TEXT,
            '-',
            ''
        );


    ------------------------------------------------------------
    -- Insert admin comment
    ------------------------------------------------------------

    INSERT INTO "support"."ticketcomment"
    (
        "id",
        "ticketId",
        "message",
        "commentBy",
        "commentType",
        "isInternal",
        "attachments",
        "createdAt",
        "updatedAt"
    )
    VALUES
    (
        v_id,
        p_ticket_id,
        p_message,
        COALESCE(NULLIF(BTRIM(p_admin_email), ''), 'admin'),
        'ADMIN',
        v_is_internal,
        p_attachments,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );


    ------------------------------------------------------------
    -- Update "support"."ticket"
    ------------------------------------------------------------

    UPDATE "support"."ticket"
    SET
        "firstResponseAt" =
            CASE
                WHEN v_first_response IS NULL
                THEN CURRENT_TIMESTAMP
                ELSE "firstResponseAt"
            END,

        "status" =
            CASE
                WHEN v_status = 'OPEN'
                     AND v_is_internal = FALSE
                THEN 'IN_PROGRESS'
                ELSE "status"
            END,

        "updatedAt" = CURRENT_TIMESTAMP

    WHERE "id" = p_ticket_id;


    ------------------------------------------------------------
    -- Return newly created comment
    ------------------------------------------------------------

    OPEN p_cursor FOR
    SELECT
        "id",
        "ticketId",
        "message",
        "commentBy",
        "commentType",
        "isInternal",
        "attachments",
        "createdAt",
        "updatedAt"
    FROM "support"."ticketcomment"
    WHERE "id" = v_id;

END;
$$;

45.
-- Purpose:
-- Retrieves help categories for the admin panel.
-- Supports searching categories by title or description and returns
-- each category along with the number of associated FAQs and videos.
-- Results are returned as normal relational rows through a refcursor.

-- this sp create from fil

CREATE OR REPLACE PROCEDURE "support"."sp_admin_get_help_categories"(
    IN p_search TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT
        c.*,
        COUNT(DISTINCT f."id") AS faq_count,
        COUNT(DISTINCT v."id") AS video_count
    FROM "support"."helpcategory" c
    LEFT JOIN "support"."helpfaq" f
        ON f."categoryId" = c."id"
    LEFT JOIN "content"."helpvideo" v
        ON v."categoryId" = c."id"
    WHERE
        p_search IS NULL
        OR BTRIM(p_search) = ''
        OR c."title" ILIKE '%' || p_search || '%'
        OR c."description" ILIKE '%' || p_search || '%'
    GROUP BY c."id"
    ORDER BY c."sortOrder";
END;
$$;

46.
-- Purpose:
-- Retrieves all FAQs for the admin helpdesk.
-- Supports optional filtering by category and searching by question
-- or answer. Also returns the related category title and linked video
-- title and URL, and orders the FAQs by sortOrder.

-- Purpose:
-- Retrieves FAQs for the admin helpdesk.
-- Supports optional searching by FAQ question or answer and optional
-- filtering by FAQ category.
-- Returns FAQ records along with their related category and video details
-- as normal relational rows through a refcursor.

CREATE OR REPLACE PROCEDURE "support"."sp_admin_get_faqs"(
    IN p_search TEXT,
    IN p_category_id VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN p_cursor FOR

    SELECT
        f."id",
        f."question",
        f."answer",
        f."categoryId",
        f."videoId",
        f."sortOrder",
        f."isActive",
        f."createdAt",
        f."updatedAt",

        c."id" AS category_id,
        c."title" AS category_title,

        v."id" AS video_id,
        v."title" AS video_title,
        v."url" AS video_url

    FROM "support"."helpfaq" f

    LEFT JOIN "support"."helpcategory" c
        ON c."id" = f."categoryId"

    LEFT JOIN "content"."helpvideo" v
        ON v."id" = f."videoId"

    WHERE
        (
            p_search IS NULL
            OR BTRIM(p_search) = ''
            OR f."question" ILIKE '%' || p_search || '%'
            OR f."answer" ILIKE '%' || p_search || '%'
        )
        AND
        (
            p_category_id IS NULL
            OR BTRIM(p_category_id) = ''
            OR f."categoryId" = p_category_id
        )

    ORDER BY f."sortOrder" ASC;

END;
$$;

47.
/*
============================================================
SP NAME:
    sp_admin_create_faq

NODE.JS FUNCTION:
    createFAQ()

PURPOSE:
    Creates a new FAQ from the admin panel.

USED BY:
    POST /admin/helpdesk/faqs

FUNCTIONALITY:
    - Validates question, answer, and categoryId.
    - Generates a unique FAQ ID.
    - Inserts the FAQ into helpfaq.
    - Returns the newly created FAQ.
    - Returns related category and video information.

REPLACES:
    prisma.helpFAQ.create()

DATABASE TABLE:
    helpfaq

RELATED TABLES:
    helpcategory
    helpvideo
============================================================
*/

CREATE OR REPLACE PROCEDURE "support"."sp_admin_create_faq"(
    IN p_question VARCHAR(191),
    IN p_answer TEXT,
    IN p_category_id VARCHAR(191),
    IN p_video_id VARCHAR(191),
    IN p_sort_order INTEGER,
    IN p_is_active BOOLEAN,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id VARCHAR(191);
BEGIN

    IF p_question IS NULL OR BTRIM(p_question) = ''
       OR p_answer IS NULL OR BTRIM(p_answer) = ''
       OR p_category_id IS NULL OR BTRIM(p_category_id) = ''
    THEN
        RAISE EXCEPTION
            'Question, answer, and categoryId are required';
    END IF;

    v_id := 'c' || REPLACE(gen_random_uuid()::TEXT, '-', '');

    INSERT INTO "support"."helpfaq" (
        "id",
        "question",
        "answer",
        "categoryId",
        "videoId",
        "sortOrder",
        "isActive",
        "createdAt",
        "updatedAt"
    )
    VALUES (
        v_id,
        p_question,
        p_answer,
        p_category_id,
        p_video_id,
        COALESCE(p_sort_order, 0),
        COALESCE(p_is_active, TRUE),
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );

    OPEN p_cursor FOR
    SELECT
        f."id",
        f."question",
        f."answer",
        f."categoryId",
        f."videoId",
        f."sortOrder",
        f."isActive",
        f."createdAt",
        f."updatedAt",

        c."id" AS category_id,
        c."title" AS category_title,

        v."id" AS video_id,
        v."title" AS video_title,
        v."url" AS video_url

    FROM "support"."helpfaq" f

    LEFT JOIN "support"."helpcategory" c
        ON c."id" = f."categoryId"

    LEFT JOIN "content"."helpvideo" v
        ON v."id" = f."videoId"

    WHERE f."id" = v_id;

END;
$$;

48.
/*
============================================================
SP NAME:
    sp_admin_update_faq

NODE.JS FUNCTION:
    updateFAQ()

API ROUTE:
    PUT /admin/helpdesk/faqs/:id

PURPOSE:
    Updates an existing FAQ from the admin panel.

FUNCTIONALITY:
    - Checks whether the FAQ exists.
    - Updates only the fields supplied by the API.
    - Keeps existing values for fields that are not supplied.
    - Allows videoId to be explicitly set to NULL.
    - Updates updatedAt.
    - Returns the updated FAQ.

REPLACES:
    prisma.helpFAQ.findUnique()
    prisma.helpFAQ.update()

DATABASE TABLE:
    helpfaq

RELATED TABLES:
    helpcategory
    helpvideo

IMPORTANT:
    p_video_id_supplied is used to distinguish:

        videoId not supplied
            â†’ keep existing videoId

        videoId supplied with value
            â†’ update videoId

        videoId supplied as NULL
            â†’ set videoId = NULL
============================================================
*/

CREATE OR REPLACE PROCEDURE "support"."sp_admin_update_faq"(
    IN p_id VARCHAR(191),
    IN p_question VARCHAR(191),
    IN p_answer TEXT,
    IN p_category_id VARCHAR(191),
    IN p_video_id VARCHAR(191),
    IN p_sort_order INTEGER,
    IN p_is_active BOOLEAN,
    IN p_video_id_supplied BOOLEAN,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Validate FAQ ID
    IF p_id IS NULL OR BTRIM(p_id) = '' THEN
        RAISE EXCEPTION 'FAQ ID is required';
    END IF;


    -- Check whether FAQ exists
    IF NOT EXISTS (
        SELECT 1
        FROM "support"."helpfaq"
        WHERE "id" = p_id
    ) THEN
        RAISE EXCEPTION 'FAQ not found';
    END IF;


    -- Update FAQ
    UPDATE "support"."helpfaq"
    SET
        "question" = COALESCE(p_question, "question"),

        "answer" = COALESCE(p_answer, "answer"),

        "categoryId" = COALESCE(
            p_category_id,
            "categoryId"
        ),

        "videoId" =
            CASE
                WHEN p_video_id_supplied = TRUE
                    THEN p_video_id
                ELSE "videoId"
            END,

        "sortOrder" = COALESCE(
            p_sort_order,
            "sortOrder"
        ),

        "isActive" = COALESCE(
            p_is_active,
            "isActive"
        ),

        "updatedAt" = CURRENT_TIMESTAMP

    WHERE "id" = p_id;


    -- Return updated FAQ
    OPEN p_cursor FOR

    SELECT
        f."id",
        f."question",
        f."answer",
        f."categoryId",
        f."videoId",
        f."sortOrder",
        f."isActive",
        f."createdAt",
        f."updatedAt",

        c."id" AS category_id,
        c."title" AS category_title,

        v."id" AS video_id,
        v."title" AS video_title,
        v."url" AS video_url

    FROM "support"."helpfaq" f

    LEFT JOIN "support"."helpcategory" c
        ON c."id" = f."categoryId"

    LEFT JOIN "content"."helpvideo" v
        ON v."id" = f."videoId"

    WHERE f."id" = p_id;

END;
$$;

49.
/*
============================================================
SP NAME:
    sp_admin_delete_faq

NODE.JS FUNCTION:
    deleteFAQ()

API ROUTE:
    DELETE /admin/helpdesk/faqs/:id

PURPOSE:
    Deletes an existing FAQ.

FUNCTIONALITY:
    - Validates FAQ ID.
    - Checks whether FAQ exists.
    - Deletes the FAQ.
    - Returns deleted FAQ ID and success message.

REPLACES:
    prisma.helpFAQ.findUnique()
    prisma.helpFAQ.delete()

DATABASE TABLE:
    helpfaq

RELATED TABLES:
    helpcategory
    helpvideo
============================================================
*/

CREATE OR REPLACE PROCEDURE "support"."sp_admin_delete_faq"(
    IN p_id VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- 1. Validate ID
    IF p_id IS NULL OR BTRIM(p_id) = '' THEN
        RAISE EXCEPTION 'FAQ ID is required';
    END IF;


    -- 2. Check whether FAQ exists
    IF NOT EXISTS (
        SELECT 1
        FROM "support"."helpfaq"
        WHERE "id" = p_id
    ) THEN
        RAISE EXCEPTION 'FAQ not found';
    END IF;


    -- 3. Delete FAQ
    DELETE FROM "support"."helpfaq"
    WHERE "id" = p_id;


    -- 4. Return result
    OPEN p_cursor FOR
    SELECT
        p_id AS id,
        'FAQ deleted successfully' AS message;

END;
$$;

50.
/*
============================================================
SP NAME:
    sp_admin_get_videos

NODE.JS FUNCTION:
    getAllVideos()

API ROUTE:
    GET /admin/helpdesk/videos

ACCESS:
    Admin

PURPOSE:
    Retrieves all help videos for the admin panel.

FUNCTIONALITY:
    - Returns all videos when no filters are provided.
    - Filters by categoryId when supplied.
    - Searches video title and description when search is supplied.
    - Returns category information.
    - Returns the number of FAQs associated with each video.
    - Orders by sortOrder ASC and createdAt DESC.

USED BY:
    Admin Helpdesk / Video Management

REPLACES:
    prisma.helpVideo.findMany()

DATABASE TABLE:
    helpvideo

RELATED TABLES:
    helpcategory
    helpfaq


============================================================
*/

CREATE OR REPLACE PROCEDURE "support"."sp_admin_get_videos"(
    IN p_search TEXT,
    IN p_category_id VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    OPEN p_cursor FOR

    SELECT
        v.*,

        -- Category information
        c."id" AS category_id,
        c."title" AS category_title,

        -- Number of FAQs using this video
        (
            SELECT COUNT(*)
            FROM "support"."helpfaq" f
            WHERE f."videoId" = v."id"
        ) AS faq_count

    FROM "content"."helpvideo" v

    LEFT JOIN "support"."helpcategory" c
        ON c."id" = v."categoryId"

    WHERE
        (
            p_category_id IS NULL
            OR BTRIM(p_category_id) = ''
            OR v."categoryId" = p_category_id
        )

        AND

        (
            p_search IS NULL
            OR BTRIM(p_search) = ''
            OR v."title" ILIKE '%' || p_search || '%'
            OR v."description" ILIKE '%' || p_search || '%'
        )

    ORDER BY
        v."sortOrder" ASC,
        v."createdAt" DESC;

END;
$$;

51.
/*
============================================================
SP NAME:
    sp_admin_create_video

NODE.JS FUNCTION:
    createVideo()

API ROUTE:
    POST /admin/helpdesk/videos

ACCESS:
    Admin

PURPOSE:
    Creates a new helpdesk video.

FUNCTIONALITY:
    - Validates title.
    - Validates video URL.
    - Generates a unique video ID.
    - Stores video and thumbnail paths.
    - Stores category and tags.
    - Sets duration to NULL.
    - Sets sortOrder to 0.
    - Sets viewCount to 0.
    - Sets isActive according to the request.
    - Returns the created video with category information.

REPLACES:
    prisma.helpVideo.create()

DATABASE TABLE:
    helpvideo

RELATED TABLES:
    helpcategory

IMPORTANT:
    File upload is handled by Node.js.
    This procedure only stores the generated file paths in the DB.
============================================================
*/

CREATE OR REPLACE PROCEDURE "content"."sp_admin_create_video"(
    IN p_title VARCHAR(191),
    IN p_description TEXT,
    IN p_url VARCHAR(191),
    IN p_thumbnail_url VARCHAR(191),
    IN p_category_id VARCHAR(191),
    IN p_tags JSONB,
    IN p_is_active BOOLEAN,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id VARCHAR(191);
BEGIN

    -- 1. Validate title
    IF p_title IS NULL OR BTRIM(p_title) = '' THEN
        RAISE EXCEPTION 'Title is required';
    END IF;


    -- 2. Validate video URL
    IF p_url IS NULL OR BTRIM(p_url) = '' THEN
        RAISE EXCEPTION 'Video URL is required';
    END IF;


    -- 3. Validate category if supplied
    IF p_category_id IS NOT NULL
       AND BTRIM(p_category_id) <> ''
    THEN
        IF NOT EXISTS (
            SELECT 1
            FROM "support"."helpcategory"
            WHERE "id" = p_category_id
        ) THEN
            RAISE EXCEPTION 'Category not found';
        END IF;
    END IF;


    -- 4. Generate video ID
    v_id := 'c' || REPLACE(gen_random_uuid()::TEXT, '-', '');


    -- 5. Insert video
    INSERT INTO "content"."helpvideo" (
        "id",
        "title",
        "description",
        "url",
        "thumbnailUrl",
        "categoryId",
        "tags",
        "duration",
        "sortOrder",
        "isActive",
        "viewCount",
        "createdAt",
        "updatedAt"
    )
    VALUES (
        v_id,
        p_title,
        p_description,
        p_url,
        p_thumbnail_url,
        NULLIF(BTRIM(p_category_id), ''),
        p_tags,
        NULL,
        0,
        COALESCE(p_is_active, TRUE),
        0,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );


    -- 6. Return created video
    OPEN p_cursor FOR
    SELECT
        v.*,
        c."id" AS category_id,
        c."title" AS category_title
    FROM "content"."helpvideo" v
    LEFT JOIN "support"."helpcategory" c
        ON c."id" = v."categoryId"
    WHERE v."id" = v_id;

END;
$$;


52.
-- SELECT * FROM "content"."helpvideo" WHERE "categoryId" = 'HC004';

-- SELECT *
-- FROM "content"."helpvideo"
-- WHERE "categoryId" = 'HC004';

/*
============================================================
SP NAME:
    sp_admin_update_video

NODE.JS FUNCTION:
    updateVideo()

API ROUTE:
    PUT /admin/helpdesk/videos/:id

ACCESS:
    Admin

PURPOSE:
    Updates an existing helpdesk video.

FUNCTIONALITY:
    - Checks whether the video exists.
    - Updates only fields supplied by the API.
    - Allows description to be explicitly set to NULL.
    - Allows categoryId to be explicitly set to NULL.
    - Allows tags to be explicitly set to NULL.
    - Allows URL to be replaced when a new video file is uploaded.
    - Allows thumbnail URL to be replaced when a new thumbnail is uploaded.
    - Updates isActive.
    - Updates updatedAt.
    - Returns the updated video with category information.

REPLACES:
    prisma.helpVideo.findUnique()
    prisma.helpVideo.update()

DATABASE TABLE:
    helpvideo

RELATED TABLES:
    helpcategory

IMPORTANT:
    File replacement and deletion remain in Node.js.
    The procedure only updates the database paths.

    The *_supplied parameters are required because NULL and
    "field was not supplied" have different meanings.
============================================================
*/

CREATE OR REPLACE PROCEDURE "content"."sp_admin_update_video"(
    IN p_id VARCHAR(191),
    IN p_title VARCHAR(191),
    IN p_description TEXT,
    IN p_url VARCHAR(191),
    IN p_thumbnail_url VARCHAR(191),
    IN p_category_id VARCHAR(191),
    IN p_tags JSONB,
    IN p_is_active BOOLEAN,
    IN p_title_supplied BOOLEAN,
    IN p_description_supplied BOOLEAN,
    IN p_url_supplied BOOLEAN,
    IN p_thumbnail_supplied BOOLEAN,
    IN p_category_supplied BOOLEAN,
    IN p_tags_supplied BOOLEAN,
    IN p_is_active_supplied BOOLEAN,

    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- 1. Validate ID
    IF p_id IS NULL OR BTRIM(p_id) = '' THEN
        RAISE EXCEPTION 'Video ID is required';
    END IF;


    -- 2. Check video exists
    IF NOT EXISTS (
        SELECT 1
        FROM "content"."helpvideo"
        WHERE "id" = p_id
    ) THEN
        RAISE EXCEPTION 'Video not found';
    END IF;


    -- 3. Validate category when supplied
    IF p_category_supplied = TRUE
       AND p_category_id IS NOT NULL
       AND BTRIM(p_category_id) <> ''
    THEN
        IF NOT EXISTS (
            SELECT 1
            FROM "support"."helpcategory"
            WHERE "id" = p_category_id
        ) THEN
            RAISE EXCEPTION 'Category not found';
        END IF;
    END IF;


    -- 4. Update video
    UPDATE "content"."helpvideo"
    SET
        "title" =
            CASE
                WHEN p_title_supplied = TRUE
                    THEN p_title
                ELSE "title"
            END,

        "description" =
            CASE
                WHEN p_description_supplied = TRUE
                    THEN p_description
                ELSE "description"
            END,

        "url" =
            CASE
                WHEN p_url_supplied = TRUE
                    THEN p_url
                ELSE "url"
            END,

        "thumbnailUrl" =
            CASE
                WHEN p_thumbnail_supplied = TRUE
                    THEN p_thumbnail_url
                ELSE "thumbnailUrl"
            END,

        "categoryId" =
            CASE
                WHEN p_category_supplied = TRUE
                    THEN p_category_id
                ELSE "categoryId"
            END,

        "tags" =
            CASE
                WHEN p_tags_supplied = TRUE
                    THEN p_tags
                ELSE "tags"
            END,

        "isActive" =
            CASE
                WHEN p_is_active_supplied = TRUE
                    THEN p_is_active
                ELSE "isActive"
            END,

        "updatedAt" = CURRENT_TIMESTAMP

    WHERE "id" = p_id;


    -- 5. Return updated video
    OPEN p_cursor FOR
    SELECT
        v.*,
        c."id" AS category_id,
        c."title" AS category_title
    FROM "content"."helpvideo" v
    LEFT JOIN "support"."helpcategory" c
        ON c."id" = v."categoryId"
    WHERE v."id" = p_id;

END;
$$;

53.
/*
============================================================
SP NAME:
    sp_admin_delete_video

NODE.JS FUNCTION:
    deleteVideo()

API ROUTE:
    DELETE /admin/helpdesk/videos/:id

ACCESS:
    Admin

PURPOSE:
    Deletes an existing helpdesk video.

FUNCTIONALITY:
    - Checks whether the video exists.
    - Deletes the database record.
    - Returns the deleted video ID and success message.

REPLACES:
    prisma.helpVideo.findUnique()
    prisma.helpVideo.delete()

DATABASE TABLE:
    helpvideo

RELATED TABLES:
    helpfaq

IMPORTANT:
    This procedure does NOT delete physical video or thumbnail
    files from disk.

    File deletion remains in Node.js using:
        fs.unlinkSync()

    This is intentional because PostgreSQL should not manage
    application-server filesystem files.
============================================================
*/

CREATE OR REPLACE PROCEDURE "content"."sp_admin_delete_video"(
    IN p_id VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- 1. Validate ID
    IF p_id IS NULL OR BTRIM(p_id) = '' THEN
        RAISE EXCEPTION 'Video ID is required';
    END IF;


    -- 2. Check video exists
    IF NOT EXISTS (
        SELECT 1
        FROM "content"."helpvideo"
        WHERE "id" = p_id
    ) THEN
        RAISE EXCEPTION 'Video not found';
    END IF;


    -- 3. Delete database record
    DELETE FROM "content"."helpvideo"
    WHERE "id" = p_id;


    -- 4. Return result
    OPEN p_cursor FOR
    SELECT
        p_id AS id,
        'Video deleted successfully' AS message;

END;
$$;


54
-- select * from "content"."helpvideo"

-- ============================================================================
-- FOLDER: webCreate/CONTACT.js
-- TABLE: contact
-- ============================================================================
-- SP NAME:
--     sp_create_contact
--
-- NODE.JS FUNCTION:
--     createContact()
--
-- PURPOSE:
--     Create a new contact form submission.
--
-- FUNCTIONALITY:
--     1. Validate required fields
--     2. Validate email format
--     3. Trim input values
--     4. Convert email to lowercase
--     5. Convert empty optional values to NULL
--     6. Insert contact record
--     7. Return the created contact
--
-- ============================================================================

DROP PROCEDURE IF EXISTS sp_create_contact(
    VARCHAR,
    VARCHAR,
    VARCHAR,
    TEXT,
    TEXT,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "content"."sp_create_contact"(
    IN p_name VARCHAR(191),
    IN p_email VARCHAR(191),
    IN p_phone VARCHAR(191),
    IN p_investment_interest TEXT,
    IN p_message TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_email_regex TEXT := '^[^\s@]+@[^\s@]+\.[^\s@]+$';
    v_contact_id VARCHAR(191);
BEGIN

    -- ============================================================
    -- Required field validation
    -- ============================================================

    IF p_name IS NULL
       OR BTRIM(p_name) = ''
       OR p_email IS NULL
       OR BTRIM(p_email) = ''
       OR p_message IS NULL
       OR BTRIM(p_message) = ''
    THEN
        RAISE EXCEPTION 'Name, email, and message are required fields';
    END IF;


    -- ============================================================
    -- Email validation
    -- ============================================================

    IF NOT BTRIM(p_email) ~* v_email_regex THEN
        RAISE EXCEPTION 'Please provide a valid email address';
    END IF;


    -- ============================================================
    -- Generate contact ID
    -- ============================================================

    v_contact_id := 'c' || REPLACE(gen_random_uuid()::TEXT, '-', '');


    -- ============================================================
    -- Insert contact
    -- ============================================================

    INSERT INTO "content"."contact" (
        contact_id,
        name,
        email,
        phone,
        investment_interest,
        message
    )
    VALUES (
        v_contact_id,
        BTRIM(p_name),
        LOWER(BTRIM(p_email)),
        NULLIF(BTRIM(p_phone), ''),
        NULLIF(BTRIM(p_investment_interest), ''),
        BTRIM(p_message)
    );


    -- ============================================================
    -- Return created contact
    -- ============================================================

    OPEN p_cursor FOR
    SELECT
        c.contact_id,
        c.name,
        c.email,
        c.phone,
        c.investment_interest,
        c.message,
        c.created_at
    FROM "content"."contact" c
    WHERE c.contact_id = v_contact_id;

END;
$$;

55.
-- ============================================================================
-- FOLDER: webCreate/CONTACT.js
-- TABLE: contact
-- ============================================================================
-- SP NAME:
--     sp_get_all_contacts
--
-- NODE.JS FUNCTION:
--     getAllContacts()
--
-- PURPOSE:
--     Get all contact form submissions for admin users with pagination.
--
-- API ROUTE:
--     GET /contact
--
-- ACCESS:
--     Private / Admin
--
-- FUNCTIONALITY:
--     1. Filter contacts by is_resolved when provided
--     2. Apply page and limit
--     3. Order by newest contact first
--     4. Calculate total contact count
--     5. Calculate total pages
--     6. Return contact records using REFCURSOR
--
-- USED BY:
--     Admin contact management
--
-- REPLACES:
--     prisma.contact.findMany()
--     prisma.contact.count()
--
-- DATABASE TABLE:
--     contact
--
-- ============================================================================

DROP PROCEDURE IF EXISTS sp_get_all_contacts(
    INTEGER,
    INTEGER,
    BOOLEAN,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "content"."sp_get_all_contacts"(
    IN p_page INTEGER,
    IN p_limit INTEGER,
    IN p_is_resolved BOOLEAN,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_page INTEGER;
    v_limit INTEGER;
    v_skip INTEGER;
    v_total_count INTEGER;
    v_total_pages INTEGER;
BEGIN

    -- ============================================================
    -- Validate page
    -- Node.js default:
    -- page = 1
    -- ============================================================

    v_page := COALESCE(p_page, 1);

    IF v_page < 1 THEN
        v_page := 1;
    END IF;


    -- ============================================================
    -- Validate limit
    -- Node.js default:
    -- limit = 20
    -- ============================================================

    v_limit := COALESCE(p_limit, 20);

    IF v_limit < 1 THEN
        v_limit := 20;
    END IF;


    -- ============================================================
    -- Calculate OFFSET
    --
    -- Node.js:
    -- skip = (page - 1) * limit
    -- ============================================================

    v_skip := (v_page - 1) * v_limit;


    -- ============================================================
    -- Get total count
    --
    -- Node.js:
    -- prisma.contact.count({ where: filter })
    -- ============================================================

    SELECT COUNT(*)
    INTO v_total_count
    FROM "content"."contact"
    WHERE
        p_is_resolved IS NULL
        OR is_resolved = p_is_resolved;


    -- ============================================================
    -- Calculate total pages
    --
    -- Node.js:
    -- Math.ceil(totalCount / take)
    -- ============================================================

    v_total_pages :=
        CEIL(v_total_count::NUMERIC / v_limit);


    -- ============================================================
    -- Return contacts + pagination information
    -- ============================================================

    OPEN p_cursor FOR

    SELECT
        c.id,
        c.contact_id,
        c.name,
        c.email,
        c.phone,
        c.investment_interest,
        c.message,
        c.is_resolved,
        c.created_at,
        c.updated_at,

        -- Pagination
        v_page AS current_page,
        v_limit AS per_page,
        v_total_count AS total_count,
        v_total_pages AS total_pages

    FROM "content"."contact" c

    WHERE
        p_is_resolved IS NULL
        OR c.is_resolved = p_is_resolved

    ORDER BY c.created_at DESC

    LIMIT v_limit
    OFFSET v_skip;

END;
$$;


56.
/*
==============================================================
SP NAME
    sp_update_contact_status

NODE.JS FUNCTION
    updateContactStatus

PURPOSE
    Update the resolved status of a contact form.

API ROUTE
    PATCH /contact/:contact_id

ACCESS
    Private / Admin

FUNCTIONALITY
    - Validates contact_id.
    - Validates is_resolved.
    - Checks whether the contact exists.
    - Updates is_resolved.
    - Updates updated_at.
    - Returns the updated contact record using REFCURSOR.

USED BY
    Admin Contact Management

REPLACES
    Prisma:
        prisma.contact.update()

DATABASE TABLE
    contact

RELATED TABLES
    None

IMPORTANT
    - contact_id is VARCHAR(191).
    - is_resolved is BOOLEAN.
    - The procedure uses contact_id, not the internal id.
    - Output is returned as normal relational columns.
    - Errors are raised so Node.js can handle them.
==============================================================
*/

DROP PROCEDURE IF EXISTS sp_update_contact_status(
    VARCHAR,
    BOOLEAN,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "content"."sp_update_contact_status"(
    IN p_contact_id VARCHAR(191),
    IN p_is_resolved BOOLEAN,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    /*
    ==========================================================
    1. Validate contact_id
    ==========================================================
    */
    IF p_contact_id IS NULL
       OR BTRIM(p_contact_id) = '' THEN

        RAISE EXCEPTION 'Contact ID is required';

    END IF;


    /*
    ==========================================================
    2. Validate is_resolved
    ==========================================================
    Node.js checks:

        if (is_resolved === undefined)

    PostgreSQL receives NULL when the value is not supplied.
    ==========================================================
    */
    IF p_is_resolved IS NULL THEN

        RAISE EXCEPTION 'is_resolved field is required';

    END IF;


    /*
    ==========================================================
    3. Check whether contact exists
    ==========================================================
    */
    IF NOT EXISTS (
        SELECT 1
        FROM "content"."contact"
        WHERE contact_id = p_contact_id
    ) THEN

        RAISE EXCEPTION 'Contact form not found';

    END IF;


    /*
    ==========================================================
    4. Update "content"."contact" status
    ==========================================================
    */
    UPDATE "content"."contact"
    SET
        is_resolved = p_is_resolved,
        updated_at = CURRENT_TIMESTAMP
    WHERE contact_id = p_contact_id;


    /*
    ==========================================================
    5. Return updated contact
    ==========================================================
    */
    OPEN p_cursor FOR

    SELECT
        c.id,
        c.contact_id,
        c.name,
        c.email,
        c.phone,
        c.investment_interest,
        c.message,
        c.is_resolved,
        c.created_at,
        c.updated_at

    FROM "content"."contact" c

    WHERE c.contact_id = p_contact_id;

END;
$$;


57.
-- select * from "content"."contact"

/*
==============================================================
SP NAME
    sp_create_bank_verification

NODE.JS FUNCTION
    createBankVerification

PURPOSE
    Create a new bank verification record.

API ROUTE
    POST /bank-verification

ACCESS
    Private / User

FUNCTIONALITY
    - Validates required bank details.
    - Requires document URL.
    - Creates account with PENDING status.
    - Sets is_primary to FALSE.
    - Returns created verification.
    - Returns user's active bank-account count.

USED BY
    User Bank Verification

REPLACES
    prisma.bankVerification.create()

DATABASE TABLE
    user.bank_verification

RELATED TABLES
    user.user
==============================================================
*/

DROP PROCEDURE IF EXISTS sp_create_bank_verification(
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    REFCURSOR
);

DROP PROCEDURE IF EXISTS sp_create_bank_verification(
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    REFCURSOR
);

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE PROCEDURE "kyc"."sp_create_bank_verification"(
    IN p_customer_number VARCHAR(191),
    IN p_holder_name VARCHAR(191),
    IN p_account_number VARCHAR(191),
    IN p_bank_name VARCHAR(191),
    IN p_branch_name VARCHAR(191),
    IN p_iban VARCHAR(191),
    IN p_document_type VARCHAR(191),
    IN p_document_url VARCHAR(191),
    IN p_ifsc_code VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id VARCHAR(191);
    v_total_accounts INTEGER;
BEGIN
    -- Validate customer number
    IF p_customer_number IS NULL
       OR BTRIM(p_customer_number) = '' THEN
        RAISE EXCEPTION 'Customer number is required';
    END IF;

    -- Validate required fields
    IF p_holder_name IS NULL OR BTRIM(p_holder_name) = ''
       OR p_account_number IS NULL OR BTRIM(p_account_number) = ''
       OR p_bank_name IS NULL OR BTRIM(p_bank_name) = ''
       OR p_branch_name IS NULL OR BTRIM(p_branch_name) = ''
       OR p_iban IS NULL OR BTRIM(p_iban) = ''
       OR p_document_type IS NULL OR BTRIM(p_document_type) = '' THEN
        RAISE EXCEPTION
            'Name, account number, bank name, branch name, IBAN, and document type are required';
    END IF;

    -- Validate document
    IF p_document_url IS NULL
       OR BTRIM(p_document_url) = '' THEN
        RAISE EXCEPTION 'Please upload the document file';
    END IF;

    -- Verify customer exists
    IF NOT EXISTS (
        SELECT 1
        FROM "user"."user"
        WHERE "customer_number" = p_customer_number
    ) THEN
        RAISE EXCEPTION 'Customer not found: %', p_customer_number;
    END IF;

    -- Generate VARCHAR ID
    v_id := 'c' || REPLACE(GEN_RANDOM_UUID()::TEXT, '-', '');

    -- Insert bank verification
    INSERT INTO "kyc"."bank_verification" (
        "id",
        "customer_number",
        "holder_name",
        "account_number",
        "bank_name",
        "branch_name",
        "ifsc_code",
        "iban",
        "document_type",
        "document_url",
        "account_status",
        "is_primary",
        "is_active",
        "createdAt",
        "updatedAt"
    )
    VALUES (
        v_id,
        p_customer_number,
        BTRIM(p_holder_name),
        BTRIM(p_account_number),
        BTRIM(p_bank_name),
        BTRIM(p_branch_name),
        NULLIF(BTRIM(p_ifsc_code), ''),
        BTRIM(p_iban),
        BTRIM(p_document_type),
        p_document_url,
        'PENDING'::"kyc_status_enum",
        FALSE,
        TRUE,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    );

    -- Count active accounts
    SELECT COUNT(*)
    INTO v_total_accounts
    FROM "kyc"."bank_verification"
    WHERE "customer_number" = p_customer_number
      AND "is_active" = TRUE;

    -- Return created record
    OPEN p_cursor FOR
    SELECT
        bv.*,
        v_total_accounts AS total_bank_accounts
    FROM "kyc"."bank_verification" AS bv
    WHERE bv."id" = v_id;
END;
$$;


58.
/*
==============================================================
SP NAME
    sp_get_my_bank_verifications

NODE.JS FUNCTION
    getMyBankVerifications

PURPOSE
    Get the authenticated user's active bank accounts.

API ROUTE
    GET /bank-verification

ACCESS
    Private / User

FUNCTIONALITY
    - Filters by customer number.
    - Only active accounts.
    - Optional account status filter.
    - Pagination.
    - Primary accounts first.
    - Newest accounts first.
    - Returns ON_HOLD reason.

DATABASE TABLE
    user.bank_verification

RELATED TABLES
    user.bank_on_hold_reason
==============================================================
*/

DROP PROCEDURE IF EXISTS sp_get_my_bank_verifications(
    VARCHAR,
    INTEGER,
    INTEGER,
    VARCHAR,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "kyc"."sp_get_my_bank_verifications"(
    IN p_customer_number VARCHAR(191),
    IN p_page INTEGER,
    IN p_limit INTEGER,
    IN p_account_status VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_page INTEGER;
    v_limit INTEGER;
    v_offset INTEGER;
    v_total_records INTEGER;
    v_total_pages INTEGER;
BEGIN
    -- Use tables without schema prefixes.
    SET LOCAL search_path TO "user", config, public;

    v_page := GREATEST(COALESCE(p_page, 1), 1);
    v_limit := GREATEST(COALESCE(p_limit, 10), 1);
    v_offset := (v_page - 1) * v_limit;

    SELECT COUNT(*)
    INTO v_total_records
    FROM "kyc"."bank_verification" AS bv
    WHERE bv."customer_number" = p_customer_number
      AND bv."is_active" = TRUE
      AND (
          p_account_status IS NULL
          OR BTRIM(p_account_status) = ''
          OR bv."account_status"::TEXT = UPPER(p_account_status)
      );

    v_total_pages :=
        CEIL(v_total_records::NUMERIC / v_limit)::INTEGER;

    OPEN p_cursor FOR
    SELECT
        bv.*,
        rt."id" AS reason_template_id,
        rt."subject" AS reason_subject,
        rt."reason" AS reason_text,
        v_page AS current_page,
        v_limit AS page_limit,
        v_total_records AS total_records,
        v_total_pages AS total_pages,
        (v_page < v_total_pages) AS has_next_page,
        (v_page > 1) AS has_previous_page
    FROM "kyc"."bank_verification" AS bv
    LEFT JOIN "catalog"."reason_templates" AS rt
        ON rt."id" = bv."onhold_template_id"
    WHERE bv."customer_number" = p_customer_number
      AND bv."is_active" = TRUE
      AND (
          p_account_status IS NULL
          OR BTRIM(p_account_status) = ''
          OR bv."account_status"::TEXT = UPPER(p_account_status)
      )
    ORDER BY
        bv."is_primary" DESC,
        bv."createdAt" DESC
    LIMIT v_limit
    OFFSET v_offset;
END;
$$;

59.
/*
==============================================================
SP NAME
    sp_get_bank_verification_by_id

NODE.JS FUNCTION
    getBankVerificationById

PURPOSE
    Get one bank verification by ID.

API ROUTE
    GET /bank-verification/:id

ACCESS
    Private

FUNCTIONALITY
    - Validates ID.
    - Returns bank verification.
    - Returns ON_HOLD reason.

DATABASE TABLE
    user.bank_verification
==============================================================
*/

DROP PROCEDURE IF EXISTS sp_get_bank_verification_by_id(
    INTEGER,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "kyc"."sp_get_bank_verification_by_id"(
    IN p_id INTEGER,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_id IS NULL OR p_id <= 0 THEN
        RAISE EXCEPTION 'Invalid bank verification ID';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM "kyc"."bank_verification"
        WHERE id = p_id
    ) THEN
        RAISE EXCEPTION 'Bank verification not found';
    END IF;

    OPEN p_cursor FOR
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
        bv.onhold_reason_id,
        r.id AS reason_id,
        r.reason_name,
        bv."createdAt",
        bv."updatedAt"
    FROM "kyc"."bank_verification" bv
    LEFT JOIN bank_on_hold_reason r
        ON r.id = bv.onhold_reason_id
    WHERE bv.id = p_id;

END;
$$;


60.
/*
==============================================================
SP NAME
    sp_update_bank_verification_status

NODE.JS FUNCTION
    updateBankVerificationStatus

PURPOSE
    Update bank verification account status.

API ROUTE
    PATCH /bank-verification/:id/status

ACCESS
    Private / Admin

FUNCTIONALITY
    - Validates verification ID.
    - Validates account status.
    - Supports PENDING, APPROVED, REJECTED, ON_HOLD.
    - Requires reason_id for ON_HOLD.
    - Rejects reason_id for other statuses.
    - Validates ON_HOLD reason.
    - Stores reason ID for ON_HOLD.
    - Clears reason when leaving ON_HOLD.
    - Returns updated verification.

DATABASE TABLE
    user.bank_verification

RELATED TABLE
    user.bank_on_hold_reason
==============================================================
*/

DROP PROCEDURE IF EXISTS sp_update_bank_verification_status(
    INTEGER,
    VARCHAR,
    INTEGER,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "kyc"."sp_update_bank_verification_status"(
    IN p_id INTEGER,
    IN p_account_status VARCHAR(191),
    IN p_reason_id INTEGER,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Use tables without schema prefixes.
    SET LOCAL search_path TO "user", config, public;

    -- Validate bank verification ID.
    IF p_id IS NULL OR p_id <= 0 THEN
        RAISE EXCEPTION 'Invalid bank verification ID';
    END IF;

    -- Validate status.
    IF p_account_status IS NULL
       OR UPPER(p_account_status) NOT IN
          ('PENDING', 'APPROVED', 'REJECTED', 'ON_HOLD') THEN
        RAISE EXCEPTION
            'Invalid status. Must be PENDING, APPROVED, REJECTED, or ON_HOLD';
    END IF;

    -- ON_HOLD requires a reason template.
    IF UPPER(p_account_status) = 'ON_HOLD'
       AND p_reason_id IS NULL THEN
        RAISE EXCEPTION
            'reason_id is required when status is ON_HOLD';
    END IF;

    -- Other statuses must not receive a reason.
    IF UPPER(p_account_status) <> 'ON_HOLD'
       AND p_reason_id IS NOT NULL THEN
        RAISE EXCEPTION
            'reason_id should only be provided when status is ON_HOLD';
    END IF;

    -- Check bank verification exists.
    IF NOT EXISTS (
        SELECT 1
        FROM "kyc"."bank_verification"
        WHERE "id" = p_id
    ) THEN
        RAISE EXCEPTION 'Bank verification not found';
    END IF;

    -- Check reason template exists for ON_HOLD.
    IF UPPER(p_account_status) = 'ON_HOLD'
       AND NOT EXISTS (
           SELECT 1
           FROM "catalog"."reason_templates"
           WHERE "id" = p_reason_id
       ) THEN
        RAISE EXCEPTION 'ON_HOLD reason not found';
    END IF;

    -- Update verification status and reason template.
    UPDATE "kyc"."bank_verification"
    SET
        "account_status" = UPPER(p_account_status)::"enum_3",
        "onhold_template_id" =
            CASE
                WHEN UPPER(p_account_status) = 'ON_HOLD'
                THEN p_reason_id
                ELSE NULL
            END,
        "updatedAt" = CURRENT_TIMESTAMP
    WHERE "id" = p_id;

    -- Return the updated verification.
    OPEN p_cursor FOR
    SELECT
        bv."id",
        bv."customer_number",
        bv."holder_name",
        bv."account_number",
        bv."bank_name",
        bv."branch_name",
        bv."ifsc_code",
        bv."iban",
        bv."document_type",
        bv."document_url",
        bv."account_status",
        bv."is_primary",
        bv."is_active",
        bv."onhold_template_id",
        rt."id" AS reason_template_id,
        rt."subject" AS reason_subject,
        rt."reason" AS reason_text,
        bv."createdAt",
        bv."updatedAt"
    FROM "kyc"."bank_verification" AS bv
    LEFT JOIN "catalog"."reason_templates" AS rt
        ON rt."id" = bv."onhold_template_id"
    WHERE bv."id" = p_id;
END;
$$;

61.
/*
==============================================================
SP NAME
    sp_on_hold_edit

NODE.JS FUNCTION
    onHoldEdit

PURPOSE
    Allow a user to edit an ON_HOLD bank verification
    and resubmit it for review.

API ROUTE
    PATCH /bank-verification/:id/on-hold

ACCESS
    Private / User

FUNCTIONALITY
    - Checks ownership.
    - Only ON_HOLD records can be edited.
    - Updates supplied fields.
    - Requires at least one field.
    - Changes status to PENDING.
    - Clears ON_HOLD reason.
    - Returns updated verification.

DATABASE TABLE
    user.bank_verification
==============================================================
*/

DROP PROCEDURE IF EXISTS sp_on_hold_edit(
    INTEGER,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    VARCHAR,
    REFCURSOR
);

CREATE OR REPLACE PROCEDURE "kyc"."sp_on_hold_edit"(
    IN p_id INTEGER,
    IN p_customer_number VARCHAR(191),
    IN p_holder_name VARCHAR(191),
    IN p_account_number VARCHAR(191),
    IN p_bank_name VARCHAR(191),
    IN p_branch_name VARCHAR(191),
    IN p_ifsc_code VARCHAR(191),
    IN p_iban VARCHAR(191),
    IN p_document_url VARCHAR(191),
    IN p_document_type VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_id IS NULL OR p_id <= 0 THEN
        RAISE EXCEPTION 'Invalid bank verification ID';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM "kyc"."bank_verification"
        WHERE id = p_id
    ) THEN
        RAISE EXCEPTION 'Bank verification not found';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM "kyc"."bank_verification"
        WHERE id = p_id
          AND customer_number = p_customer_number
    ) THEN
        RAISE EXCEPTION
            'You can only edit your own bank verifications.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM "kyc"."bank_verification"
        WHERE id = p_id
          AND account_status = 'ON_HOLD'
    ) THEN

        RAISE EXCEPTION
            'Only ON_HOLD accounts can be edited. Current status is not ON_HOLD';

    END IF;

    IF p_holder_name IS NULL
       AND p_account_number IS NULL
       AND p_bank_name IS NULL
       AND p_branch_name IS NULL
       AND p_ifsc_code IS NULL
       AND p_iban IS NULL
       AND p_document_url IS NULL
       AND p_document_type IS NULL THEN

        RAISE EXCEPTION
            'No fields provided to update. Please provide at least one field to update.';

    END IF;

    UPDATE "kyc"."bank_verification"
    SET
        holder_name =
            CASE
                WHEN p_holder_name IS NOT NULL
                     AND BTRIM(p_holder_name) <> ''
                THEN BTRIM(p_holder_name)
                ELSE holder_name
            END,

        account_number =
            CASE
                WHEN p_account_number IS NOT NULL
                     AND BTRIM(p_account_number) <> ''
                THEN BTRIM(p_account_number)
                ELSE account_number
            END,

        bank_name =
            CASE
                WHEN p_bank_name IS NOT NULL
                     AND BTRIM(p_bank_name) <> ''
                THEN BTRIM(p_bank_name)
                ELSE bank_name
            END,

        branch_name =
            CASE
                WHEN p_branch_name IS NOT NULL
                     AND BTRIM(p_branch_name) <> ''
                THEN BTRIM(p_branch_name)
                ELSE branch_name
            END,

        ifsc_code =
            CASE
                WHEN p_ifsc_code IS NOT NULL
                THEN BTRIM(p_ifsc_code)
                ELSE ifsc_code
            END,

        iban =
            CASE
                WHEN p_iban IS NOT NULL
                     AND BTRIM(p_iban) <> ''
                THEN BTRIM(p_iban)
                ELSE iban
            END,

        document_url =
            CASE
                WHEN p_document_url IS NOT NULL
                THEN p_document_url
                ELSE document_url
            END,

        document_type =
            CASE
                WHEN p_document_type IS NOT NULL
                     AND BTRIM(p_document_type) <> ''
                THEN BTRIM(p_document_type)
                ELSE document_type
            END,

        account_status = 'PENDING',
        onhold_reason_id = NULL,
        "updatedAt" = CURRENT_TIMESTAMP

    WHERE id = p_id;

    OPEN p_cursor FOR
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
        bv.onhold_reason_id,
        bv."createdAt",
        bv."updatedAt"
    FROM "kyc"."bank_verification" bv
    WHERE bv.id = p_id;

END;
$$;

62.
/* ============================================================
   SP NAME        : sp_get_all_bank_verifications

   NODE.JS FUNCTION : getAllBankVerifications()

   PURPOSE :
   Fetch all active bank verifications for ADMIN/SUPER_ADMIN.

   API ROUTE :
   GET /bank-verification/all

   ACCESS :
   Private - ADMIN / SUPER_ADMIN

   FUNCTIONALITY :
   - Pagination
   - Search by customer/account/bank/IBAN/user information
   - Filter by account status
   - Filter by bank name
   - Filter by primary account
   - Filter by customer number
   - Determine latest account per customer
   - Return account/status counts

   IMPORTANT :
   CSV generation remains in Node.js.
   This SP returns relational rows through REFCURSOR.
   ============================================================ */

DROP PROCEDURE IF EXISTS sp_get_all_bank_verifications(
    INTEGER,
    INTEGER,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN,
    VARCHAR,
    BOOLEAN,
    REFCURSOR
);

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

CREATE OR REPLACE PROCEDURE "kyc"."sp_send_on_hold_reminder"(
    IN p_id INTEGER,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_id IS NULL THEN
        RAISE EXCEPTION 'Invalid bank verification ID';
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM "kyc"."bank_verification"
        WHERE id = p_id
    ) THEN
        RAISE EXCEPTION 'Bank verification not found';
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM "kyc"."bank_verification"
        WHERE id = p_id
          AND account_status = 'ON_HOLD'
    ) THEN
        RAISE EXCEPTION
            'Cannot send reminder: bank verification is not ON_HOLD';
    END IF;

    OPEN p_cursor FOR
    SELECT
        bv.id AS verification_id,

        u."userId",
        u.customer_number,
        u.first_name,
        u.last_name,
        u.email AS recipient,

        bv.holder_name,
        bv.account_number,
        bv.bank_name,

        rt.id AS reason_id,
        rt.reason AS reason_name,

        rt.subject,
        rt.html_content AS html_template

    FROM "kyc"."bank_verification" bv

    LEFT JOIN "user"."user" u
        ON u.customer_number = bv.customer_number

    LEFT JOIN "catalog"."reason_templates" rt
        ON rt.id = bv.onhold_template_id
       AND rt.reason_type = 'ON_HOLD'

    WHERE bv.id = p_id

      AND bv.account_status = 'ON_HOLD';

END;
$$;

70.
-- ================================================================
-- KYC STORED PROCEDURES
-- Source folder: src/controllers/kyc
-- Source file: kyc.controller.js
--
-- These procedures contain database logic only. Facia API calls,
-- HTTP responses, redirects, and email notifications remain in JS.
-- Results are returned as rows through REFCURSOR.
-- ================================================================

-- ---------------------------------------------------------------
-- sp_kyc_get_status
-- Source function: getKYCStatus
-- Purpose: Returns the user's KYC flags and latest KYC details.
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE "kyc"."sp_kyc_get_status"(
    IN p_user_id INTEGER,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql AS $$
BEGIN
    SET LOCAL search_path TO "user", public;
    OPEN p_cursor FOR
    SELECT
        u."id" AS user_id,
        u."is_kyc_verified",
        u."kyc_status",
        u."customer_number",
        u."phone_prefix",
        k."full_name",
        k."date_of_birth",
        k."gender",
        k."address",
        k."document_type",
        k."status" AS kyc_record_status,
        k."decline_reason",
        k."verified_at",
        k."created_at" AS kyc_created_at,
        CASE WHEN u."phone_prefix" = '+971'
             THEN 'passport'
             ELSE 'id_card,passport,driving_license'
        END AS allowed_document_types
    FROM "user"."user" u
    LEFT JOIN LATERAL (
        SELECT * FROM "kyc"."kyc" k1
        WHERE k1."customer_number" = u."customer_number"
        ORDER BY k1."created_at" DESC
        LIMIT 1
    ) k ON TRUE
    WHERE u."id" = p_user_id;
END;
$$;

71.
-- ---------------------------------------------------------------
-- sp_kyc_get_all
-- Source function: getAllKYCs
-- Purpose: Lists KYC records with status/search filters and pagination.
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE "kyc"."sp_kyc_get_all"(
    IN p_page INTEGER,
    IN p_limit INTEGER,
    IN p_status VARCHAR(191),
    IN p_search TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page INTEGER := GREATEST(COALESCE(p_page, 1), 1);
    v_limit INTEGER := GREATEST(COALESCE(p_limit, 10), 1);
    v_total BIGINT;
BEGIN
    SET LOCAL search_path TO "user", public;
    SELECT COUNT(*) INTO v_total
    FROM "kyc"."kyc" k
    WHERE (p_status IS NULL OR k."status" = p_status)
      AND (p_search IS NULL OR k."customer_number" ILIKE '%' || p_search || '%'
        OR k."full_name" ILIKE '%' || p_search || '%'
        OR k."document_number" ILIKE '%' || p_search || '%');

    OPEN p_cursor FOR
    SELECT
        k."id", k."kyc_id", k."user_id", k."customer_number",
        k."full_name", k."date_of_birth", k."gender", k."address",
        k."document_type", k."document_number", k."reference_id",
        k."status", k."decline_reason", k."verified_at",
        k."created_at", k."updated_at",
        v_total AS total_count,
        v_page AS current_page,
        v_limit AS page_limit,
        CEIL(v_total::NUMERIC / v_limit)::INTEGER AS total_pages,
        (v_page < CEIL(v_total::NUMERIC / v_limit)::INTEGER) AS has_next_page,
        (v_page > 1) AS has_previous_page
    FROM "kyc"."kyc" k
    WHERE (p_status IS NULL OR k."status" = p_status)
      AND (p_search IS NULL OR k."customer_number" ILIKE '%' || p_search || '%'
        OR k."full_name" ILIKE '%' || p_search || '%'
        OR k."document_number" ILIKE '%' || p_search || '%')
    ORDER BY k."created_at" DESC
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;
END;
$$;

72.
-- ---------------------------------------------------------------
-- sp_kyc_get_by_id
-- Source function: getKYCById
-- Purpose: Finds one KYC row by numeric id or kyc_id and includes facia_response.
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE "kyc"."sp_kyc_get_by_id"(
    IN p_kyc_identifier VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql AS $$
BEGIN
    SET LOCAL search_path TO "user", public;
    OPEN p_cursor FOR
    SELECT *
    FROM "kyc"."kyc" k
    WHERE k."kyc_id" = p_kyc_identifier
       OR (p_kyc_identifier ~ '^[0-9]+$' AND k."id" = p_kyc_identifier::INTEGER);
END;
$$;

73.
-- ---------------------------------------------------------------
-- sp_kyc_admin_reset
-- Source function: adminResetKyc
-- Purpose: Finds a user by id/email/customer number, deletes all KYC rows,
-- resets user verification flags, and returns the updated user.
-- ---------------------------------------------------------------
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
CREATE OR REPLACE PROCEDURE "kyc"."sp_kyc_admin_verify"(
    IN p_identifier VARCHAR(191),
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql AS $$
DECLARE v_user_id INTEGER; v_customer_number VARCHAR(191); v_email VARCHAR(191); v_first VARCHAR(191); v_last VARCHAR(191); v_kyc_id INTEGER;
BEGIN
    SET LOCAL search_path TO "user", public;
    SELECT u."id",u."customer_number",u."email",u."first_name",u."last_name" INTO v_user_id,v_customer_number,v_email,v_first,v_last
    FROM "user"."user" u WHERE (p_identifier ~ '^[0-9]+$' AND u."id"=p_identifier::INTEGER) OR u."email"=p_identifier OR u."customer_number"=p_identifier LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found with identifier: %', p_identifier; END IF;
    UPDATE "user"."user" SET "is_kyc_verified"=TRUE,"kyc_status"='VERIFIED'::"enum_16","updated_at"=CURRENT_TIMESTAMP WHERE "id"=v_user_id;
    SELECT k."id" INTO v_kyc_id FROM "kyc"."kyc" k WHERE k."customer_number"=v_customer_number ORDER BY k."created_at" DESC LIMIT 1;
    IF v_kyc_id IS NULL THEN INSERT INTO "kyc"."kyc"("user_id","customer_number","full_name","status","verified_at","created_at","updated_at") VALUES(v_user_id,v_customer_number,COALESCE(NULLIF(BTRIM(COALESCE(v_first,'')||' '||COALESCE(v_last,'')),''),v_email),'ACCEPTED',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) RETURNING "id" INTO v_kyc_id;
    ELSE UPDATE "kyc"."kyc" SET "status"='ACCEPTED',"verified_at"=CURRENT_TIMESTAMP,"updated_at"=CURRENT_TIMESTAMP WHERE "id"=v_kyc_id; END IF;
    OPEN p_cursor FOR SELECT u."id",u."email",u."first_name",u."last_name",u."customer_number",u."is_kyc_verified",u."kyc_status",k."full_name",k."status",k."verified_at" FROM "user"."user" u JOIN "kyc"."kyc" k ON k."id"=v_kyc_id WHERE u."id"=v_user_id;
END;
$$;

75
-- ---------------------------------------------------------------
-- sp_kyc_admin_reject
-- Source function: adminRejectKyc
-- Purpose: Marks the user and newest/created KYC row as declined with a reason.
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE "kyc"."sp_kyc_admin_reject"(
    IN p_identifier VARCHAR(191),
    IN p_reason TEXT,
    INOUT p_cursor REFCURSOR
)
LANGUAGE plpgsql AS $$
DECLARE v_user_id INTEGER; v_customer_number VARCHAR(191); v_email VARCHAR(191); v_first VARCHAR(191); v_kyc_id INTEGER;
BEGIN
    SET LOCAL search_path TO "user", public;
    IF p_reason IS NULL OR BTRIM(p_reason)='' THEN RAISE EXCEPTION 'Rejection reason is required'; END IF;
    SELECT u."id",u."customer_number",u."email",u."first_name" INTO v_user_id,v_customer_number,v_email,v_first FROM "user"."user" u WHERE (p_identifier ~ '^[0-9]+$' AND u."id"=p_identifier::INTEGER) OR u."email"=p_identifier OR u."customer_number"=p_identifier LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found with identifier: %',p_identifier; END IF;
    UPDATE "user"."user" SET "is_kyc_verified"=FALSE,"kyc_status"='DECLINED'::"enum_16","updated_at"=CURRENT_TIMESTAMP WHERE "id"=v_user_id;
    SELECT k."id" INTO v_kyc_id FROM "kyc"."kyc" k WHERE k."customer_number"=v_customer_number ORDER BY k."created_at" DESC LIMIT 1;
    IF v_kyc_id IS NULL THEN INSERT INTO "kyc"."kyc"("user_id","customer_number","full_name","status","decline_reason","created_at","updated_at") VALUES(v_user_id,v_customer_number,COALESCE(v_first,v_email),'DECLINED',BTRIM(p_reason),CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) RETURNING "id" INTO v_kyc_id;
    ELSE UPDATE "kyc"."kyc" SET "status"='DECLINED',"decline_reason"=BTRIM(p_reason),"verified_at"=NULL,"updated_at"=CURRENT_TIMESTAMP WHERE "id"=v_kyc_id; END IF;
    OPEN p_cursor FOR SELECT u."id",u."email",u."customer_number",u."is_kyc_verified",u."kyc_status",k."full_name",k."status",k."decline_reason" FROM "user"."user" u JOIN "kyc"."kyc" k ON k."id"=v_kyc_id WHERE u."id"=v_user_id;
END;
$$;



-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.sukuk_inventory.findFirst(...)
-- Purpose: Fetch an active Sukuk inventory row for trading and lock it for the current transaction.
CREATE OR REPLACE PROCEDURE "trade"."sp_trade_get_inventory"(
    p_inventory_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT i.* FROM "trade"."sukuk_inventory" i WHERE i.inventory_id = p_inventory_id AND i.is_active = true ;
END $$;

-- Function: buySukuk
-- Prisma await: await tx.user.findFirst(...)
-- Purpose: Fetch the user row required by the buy flow.

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

CREATE OR REPLACE PROCEDURE "payments"."sp_trade_get_wallet"(
    p_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT w.* FROM "payments"."wallet" w WHERE w.customer_number = p_customer_number AND w.is_active = true AND w.status::text = 'ACTIVE';
END $$;

-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.wallet.update(...)
-- Purpose: Update "payments"."wallet" balance and return the updated wallet row.
CREATE OR REPLACE PROCEDURE "payments"."sp_trade_update_wallet"(
    p_wallet_id integer,
    p_balance numeric,
    INOUT p_cursor refcursor DEFAULT 'result_cursor' 
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "payments"."wallet"
    SET balance = p_balance,
        last_transaction = clock_timestamp(),
        updated_at = clock_timestamp()
    WHERE id = p_wallet_id;

    OPEN p_cursor FOR SELECT w.* FROM "payments"."wallet" w WHERE w.id = p_wallet_id;
END $$;

-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.sukuk_inventory.update(...)
-- Purpose: Update fractional/full Sukuk inventory quantity and return the updated inventory row.
CREATE OR REPLACE PROCEDURE "trade"."sp_trade_update_inventory_quantity"(
    p_inventory_pk integer,
    p_purchase_type varchar,
    p_quantity double precision,
    INOUT p_cursor refcursor DEFAULT 'result_cursor' 
)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_purchase_type = 'Fractional' THEN
        UPDATE "trade"."sukuk_inventory"
        SET "fractionalQuantity" = p_quantity, updated_at = clock_timestamp()
        WHERE id = p_inventory_pk;
    ELSE
        UPDATE "trade"."sukuk_inventory"
        SET quantity = p_quantity::integer, updated_at = clock_timestamp()
        WHERE id = p_inventory_pk;
    END IF;
    OPEN p_cursor FOR SELECT i.* FROM "trade"."sukuk_inventory" i WHERE i.id = p_inventory_pk;
END $$;

-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.portfolio.findFirst(...)
-- Purpose: Fetch and lock a customer portfolio position for an inventory item.
CREATE OR REPLACE PROCEDURE "trade"."sp_trade_get_portfolio"(
    p_customer_number varchar,
    p_inventory_id varchar,
    p_is_active boolean DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT p.* FROM "trade"."portfolio" p WHERE p.customer_number = p_customer_number AND p.inventory_id = p_inventory_id AND (p_is_active IS NULL OR p.is_active = p_is_active) FOR UPDATE;
END $$;

-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.portfolio.update(...)
-- Purpose: Update an existing portfolio position and return the updated row.
CREATE OR REPLACE PROCEDURE "trade"."sp_trade_update_portfolio"(
    p_portfolio_id integer,
    p_quantity integer,
    p_total_invested numeric,
    p_average_buy_price numeric DEFAULT NULL,
    p_is_active boolean DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor' 
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "trade"."portfolio"
    SET quantity = p_quantity,
        total_invested = p_total_invested,
        average_buy_price = COALESCE(p_average_buy_price, average_buy_price),
        is_active = COALESCE(p_is_active, is_active),
        updated_at = clock_timestamp()
    WHERE id = p_portfolio_id;
    OPEN p_cursor FOR SELECT p.* FROM "trade"."portfolio" p WHERE p.id = p_portfolio_id;
END $$;

-- Function: buySukuk
-- Prisma await: await tx.portfolio.create(...)
-- Purpose: Create a new portfolio position and return the created row.
CREATE OR REPLACE PROCEDURE "trade"."sp_buy_create_portfolio"(
    p_customer_number varchar,
    p_inventory_id varchar,
    p_quantity integer,
    p_average_buy_price numeric,
    p_total_invested numeric,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$n          
DECLARE v_id integer;
BEGIN
    LOCK TABLE portfolio IN SHARE ROW EXCLUSIVE MODE;
    SELECT COALESCE(MAX(id),0)+1 INTO v_id FROM "trade"."portfolio";
    INSERT INTO "trade"."portfolio"(id, portfolio_id, customer_number, inventory_id, quantity,
                          average_buy_price, total_invested, is_active, created_at, updated_at)
    VALUES(v_id, 'pf_'||md5(random()::text||clock_timestamp()::text), p_customer_number,
           p_inventory_id, p_quantity, p_average_buy_price, p_total_invested, true,
           clock_timestamp(), clock_timestamp());
    OPEN p_cursor FOR SELECT p.* FROM "trade"."portfolio" p WHERE p.id = v_id;
END $$;

-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.transaction.create(...)
-- Purpose: Create a Sukuk trade transaction and return the created transaction row.

CREATE OR REPLACE PROCEDURE "trade"."sp_trade_create_transaction"(
    p_customer_number varchar,
    p_inventory_id varchar,
    p_transaction_type transaction_type_enum,
    p_quantity integer,
    p_price_per_unit numeric,
    p_accrued_interest numeric,
    p_blox_value numeric,
    p_total_amount numeric,
    p_commission numeric,
    p_currency varchar,
    p_wallet_balance_before numeric,
    p_wallet_balance_after numeric,
    p_status status_enum,
    p_notes text DEFAULT NULL,
    p_total_amount_with_commission numeric DEFAULT NULL,
    p_ytm double precision DEFAULT NULL,
    p_ytc double precision DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE v_id integer;
BEGIN
    LOCK TABLE "transaction" IN SHARE ROW EXCLUSIVE MODE;
    SELECT COALESCE(MAX(id),0)+1 INTO v_id FROM "trade"."transaction";
    INSERT INTO "trade"."transaction"(
        id, transaction_id, customer_number, inventory_id, transaction_type, quantity,
        price_per_unit, accrued_interest, blox_value, total_amount, commission, currency,
        wallet_balance_before, wallet_balance_after, status, transaction_date, notes,
        created_at, updated_at, "totalAmountWithCommission", ytm, ytc)
    VALUES(
        v_id, 'txn_'||md5(random()::text||clock_timestamp()::text),
        p_customer_number, p_inventory_id, p_transaction_type, p_quantity,
        p_price_per_unit, p_accrued_interest, p_blox_value, p_total_amount,
        COALESCE(p_commission, 0), p_currency, p_wallet_balance_before,
        p_wallet_balance_after, p_status, clock_timestamp(), p_notes,
        clock_timestamp(), clock_timestamp(), p_total_amount_with_commission,
        p_ytm, p_ytc);
    OPEN p_cursor FOR SELECT t.* FROM "trade"."transaction" t WHERE t.id = v_id;
END $$;

-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.walletTransaction.create(...)
-- Purpose: Create a wallet transaction and return the created row.

CREATE OR REPLACE PROCEDURE "payments"."sp_trade_create_wallet_transaction"(
    p_customer_number varchar,
    p_transaction_type wallet_trans_type,
    p_amount numeric,
    p_currency varchar,
    p_wallet_balance_before numeric,
    p_wallet_balance_after numeric,
    p_status status_enum,
    p_reference_id varchar DEFAULT NULL,
    p_notes text DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE v_id varchar(191) := 'wtx_'||md5(random()::text||clock_timestamp()::text);
BEGIN
    INSERT INTO "payments"."wallet_transaction"(id, customer_number, transaction_type, amount, currency,
        wallet_balance_before, wallet_balance_after, status, reference_id, notes, created_at, updated_at)
    VALUES(v_id, p_customer_number, p_transaction_type, p_amount, p_currency,
        p_wallet_balance_before, p_wallet_balance_after, p_status, p_reference_id, p_notes,
        clock_timestamp(), clock_timestamp());
    OPEN p_cursor FOR SELECT w.* FROM "payments"."wallet_transaction" w WHERE w.id = v_id;
END $$;

-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.sukukInvestment.findFirst(...)
-- Purpose: Fetch and lock a Sukuk investment row.
CREATE OR REPLACE PROCEDURE "trade"."sp_trade_get_investment"(
    p_inventory_id varchar,
    p_customer_number varchar,
    p_is_active boolean DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT i.* FROM "trade"."sukuk_investment" i WHERE i.inventory_id = p_inventory_id AND i.customer_number = p_customer_number AND (p_is_active IS NULL OR i.is_active = p_is_active) FOR UPDATE;
END $$;

-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.sukukInvestment.update(...)
-- Purpose: Update Sukuk investment principal/status and return the updated row.
CREATE OR REPLACE PROCEDURE "trade"."sp_trade_update_investment"(
    p_investment_id integer,
    p_principal numeric,
    p_is_active boolean DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor' 
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "trade"."sukuk_investment"
    SET principal = p_principal,
        is_active = COALESCE(p_is_active, is_active),
        updated_at = clock_timestamp()
    WHERE id = p_investment_id;
    OPEN p_cursor FOR SELECT i.* FROM "trade"."sukuk_investment" i WHERE i.id = p_investment_id;
END $$;

-- Function: buySukuk
-- Prisma await: await tx.sukukInvestment.create(...)
-- Purpose: Create a Sukuk investment and return the created row.
-- =========================================
-- PROCEDURE: Create Sukuk Investment
-- =========================================
CREATE OR REPLACE PROCEDURE "trade"."sp_buy_create_investment"(
    p_inventory_id varchar,
    p_customer_number varchar,
    p_principal numeric,
    p_is_final_maturity boolean,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id integer;
BEGIN

    -- Validation
    IF p_principal IS NULL OR p_principal <= 0 THEN
        RAISE EXCEPTION 'Investment principal must be greater than zero';
    END IF;

    -- Lock table while generating next ID
    LOCK TABLE sukuk_investment
    IN SHARE ROW EXCLUSIVE MODE;

    -- Generate next ID
    SELECT COALESCE(MAX(id), 0) + 1
    INTO v_id
    FROM "trade"."sukuk_investment";

    -- Insert investment
    INSERT INTO "trade"."sukuk_investment"
    (
        id,
        investment_id,
        inventory_id,
        customer_number,
        principal,
        is_final_maturity,
        is_active,
        created_at,
        updated_at
    )
    VALUES
    (
        v_id,
        'inv_' || md5(random()::text || clock_timestamp()::text),
        p_inventory_id,
        p_customer_number,
        p_principal,
        p_is_final_maturity,
        true,
        clock_timestamp(),
        clock_timestamp()
    );

    -- Success message
    RAISE NOTICE 'Investment created successfully';

    -- Return inserted record
    OPEN p_cursor FOR
    SELECT *
    FROM "trade"."sukuk_investment"
    WHERE id = v_id;

END;
$$;
-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.sukukCallEvent.findMany(...)
-- Purpose: Fetch pending Sukuk call events in call-date order.
CREATE OR REPLACE PROCEDURE "trade"."sp_trade_get_pending_events"(
    p_inventory_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT e.* FROM "trade"."sukuk_call_event" e WHERE e.inventory_id = p_inventory_id AND e.status::text = 'PENDING' ORDER BY e.call_date;
END $$;

-- Function: buySukuk, sellSukuk
-- Prisma await: await tx.sukukInvestmentCredit.updateMany(...)
-- Purpose: Update pending investment credit amounts and return affected-row count.
CREATE OR REPLACE PROCEDURE "trade"."sp_trade_update_investment_credit"(
    p_call_event_id integer,
    p_investment_id integer,
    p_profit_amount numeric,
    p_principal_amount numeric,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_count integer;
BEGIN
    UPDATE "trade"."sukuk_investment_credit"
    SET profit_amount = p_profit_amount,
        principal_amount = p_principal_amount,
        updated_at = clock_timestamp()
    WHERE call_event_id = p_call_event_id
      AND investment_id = p_investment_id
      AND wallet_credited_at IS NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    OPEN p_cursor FOR
    SELECT v_count AS affected_rows;
END $$;

-- Function: sellSukuk
-- Prisma await: await tx.sukukInvestmentCredit.deleteMany(...)
-- Purpose: Delete uncredited investment-credit rows and return affected-row count.
CREATE OR REPLACE PROCEDURE "trade"."sp_sell_delete_investment_credits"(
    p_investment_id integer,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count integer;
BEGIN

    -- Validate record exists and is eligible for deletion
    IF NOT EXISTS (
        SELECT 1
        FROM "trade"."sukuk_investment_credit"
        WHERE investment_id = p_investment_id
          AND wallet_credited_at IS NULL
    ) THEN
        RAISE EXCEPTION
            'Investment ID % is not available or already deleted',
            p_investment_id;
    END IF;

    -- Delete record
    DELETE FROM "trade"."sukuk_investment_credit"
    WHERE investment_id = p_investment_id
      AND wallet_credited_at IS NULL;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- Return result
    OPEN p_cursor FOR
    SELECT
        v_count AS affected_rows,
        'Investment credit deleted successfully'::varchar AS message;

END;
$$;

-- Function: buySukuk
-- Prisma await: await tx.sukukInvestmentCredit.create(...)
-- Purpose: Create an investment credit row and return the created record.
CREATE OR REPLACE PROCEDURE "trade"."sp_buy_create_investment_credit"(
    p_call_event_id integer,
    p_investment_id integer,
    p_customer_number varchar,
    p_profit_amount numeric,
    p_principal_amount numeric,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE v_id integer;
BEGIN
    LOCK TABLE sukuk_investment_credit IN SHARE ROW EXCLUSIVE MODE;
    SELECT COALESCE(MAX(id),0)+1 INTO v_id FROM "trade"."sukuk_investment_credit";
    INSERT INTO "trade"."sukuk_investment_credit"(id, credit_id, call_event_id, investment_id,
        customer_number, profit_amount, principal_amount, created_at, updated_at)
    VALUES(v_id, 'credit_'||md5(random()::text||clock_timestamp()::text), p_call_event_id,
        p_investment_id, p_customer_number, p_profit_amount, p_principal_amount,
        clock_timestamp(), clock_timestamp());
    OPEN p_cursor FOR SELECT c.* FROM "trade"."sukuk_investment_credit" c WHERE c.id = v_id;
END $$;

-- Function: getAllTransactions
-- Prisma await: await prisma.transaction.count(...)
-- Prisma await: await prisma.transaction.findMany(...)
-- Purpose: Fetch paginated trade transactions using optional filters.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_all_transactions"(
    p_page integer DEFAULT 1,
    p_limit integer DEFAULT 10,
    p_transaction_type varchar DEFAULT NULL,
    p_status varchar DEFAULT NULL,
    p_customer_number varchar DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT t.*, i.name AS sukuk_name, i.issuer AS sukuk_issuer, i.isin AS sukuk_isin, count(*) OVER() AS total_count
FROM "trade"."transaction" t
JOIN "trade"."sukuk_inventory" i ON i.inventory_id = t.inventory_id
WHERE (p_transaction_type IS NULL OR t.transaction_type::text = p_transaction_type)
  AND (p_status IS NULL OR t.status::text = p_status)
  AND (p_customer_number IS NULL OR t.customer_number = p_customer_number)
ORDER BY t.transaction_date DESC
OFFSET (GREATEST(p_page,1)-1)*p_limit
LIMIT p_limit;
END $$;

-- Function: getTransactionsByUserId
-- Prisma await: await prisma.transaction.count(...)
-- Prisma await: await prisma.transaction.findMany(...)
-- Prisma await: await prisma.walletTransaction.findMany(...)
-- Purpose: Fetch a customer transaction timeline combining trade and wallet transactions.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_transactions_by_user_id"(
    p_customer_number varchar,
    p_page integer DEFAULT 1,
    p_limit integer DEFAULT 10,
    p_transaction_type varchar DEFAULT NULL,
    p_status varchar DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT * FROM (
    SELECT t.transaction_id::varchar AS id, t.transaction_type::text AS type,
           t.status::text AS status, t.total_amount AS amount, t.currency,
           t.transaction_date AS occurred_at, 'TRADE'::text AS source,
           t.inventory_id::varchar AS inventory_id,
           i.name::text AS sukuk_name, i.issuer::text AS sukuk_issuer
    FROM "trade"."transaction" t
    LEFT JOIN "trade"."sukuk_inventory" i ON i.inventory_id = t.inventory_id
    WHERE t.customer_number = p_customer_number
      AND (p_transaction_type IS NULL OR t.transaction_type::text = p_transaction_type)
      AND (p_status IS NULL OR t.status::text = p_status)
    UNION ALL
    SELECT w.id::varchar, w.transaction_type::text, w.status::text, w.amount,
           w.currency, w.created_at, 'WALLET'::text, NULL::varchar, NULL::text, NULL::text
    FROM "payments"."wallet_transaction" w
    WHERE w.customer_number = p_customer_number
) x
ORDER BY occurred_at DESC
OFFSET (GREATEST(p_page,1)-1)*p_limit
LIMIT p_limit;
END $$;

-- Function: getUserPortfolio
-- Prisma await: await prisma.portfolio.findMany(...)
-- Purpose: Fetch all active portfolio positions for a customer.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_user_portfolio"(
    p_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT p.*, i.name AS sukuk_name, i.issuer AS sukuk_issuer, i.isin AS sukuk_isin,
       i.currency AS sukuk_currency, i."bidPrice" AS current_bid_price, i."askPrice" AS current_ask_price
FROM "trade"."portfolio" p
JOIN "trade"."sukuk_inventory" i ON i.inventory_id = p.inventory_id
WHERE p.customer_number = p_customer_number AND p.is_active = true
ORDER BY p.created_at DESC;
END $$;

-- Function: getTransactionHistoryByInventory
-- Prisma await: await prisma.portfolio.findFirst(...)
-- Prisma await: await prisma.transaction.findMany(...) [BUY]
-- Prisma await: await prisma.transaction.findMany(...) [SELL]
-- Prisma await: await prisma.sukuk_inventory.findUnique(...)
-- Purpose: Fetch BUY/SELL transaction history for one customer and inventory item.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_transaction_history_by_inventory"(
    p_customer_number varchar,
    p_inventory_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT t.*, i.name AS sukuk_name, i.issuer AS sukuk_issuer,
       p.quantity AS portfolio_quantity, p.average_buy_price AS portfolio_average_buy_price,
       p.total_invested AS portfolio_total_invested
FROM "trade"."transaction" t
JOIN "trade"."sukuk_inventory" i ON i.inventory_id = t.inventory_id
LEFT JOIN "trade"."portfolio" p ON p.customer_number = t.customer_number
                     AND p.inventory_id = t.inventory_id
                     AND p.is_active = true
WHERE t.customer_number = p_customer_number
  AND t.inventory_id = p_inventory_id
  AND t.transaction_type::text IN ('BUY','SELL')
  AND t.status::text = 'COMPLETED'
ORDER BY t.transaction_date;
END $$;

-- Function: getUserPortfolioSummary
-- Prisma await: await prisma.portfolio.findMany(...)
-- Purpose: Fetch active portfolio rows used to calculate/display portfolio summary.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_user_portfolio_summary"(
    p_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT p.*, i.name AS sukuk_name, i.issuer AS sukuk_issuer, i.isin AS sukuk_isin,
       i.currency AS sukuk_currency, i."bidPrice" AS current_bid_price, i."askPrice" AS current_ask_price
FROM "trade"."portfolio" p
JOIN "trade"."sukuk_inventory" i ON i.inventory_id = p.inventory_id
WHERE p.customer_number = p_customer_number AND p.is_active = true
ORDER BY p.created_at DESC;
END $$;

-- Function: downloadInvoice
-- Prisma await: await prisma.transaction.findFirst(...)
-- Prisma await: await prisma.user.findFirst(...)
-- Purpose: Fetch transaction data used for invoice generation with inventory/user reference columns.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_invoice_data"(
    p_transaction_id varchar,
    p_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT t.*, i.name AS sukuk_name, i.issuer AS sukuk_issuer, i.isin AS sukuk_isin,
       i.currency AS sukuk_currency, u.customer_number AS user_customer_number
FROM "trade"."transaction" t
JOIN "trade"."sukuk_inventory" i ON i.inventory_id = t.inventory_id
JOIN "user"."user" u ON u.customer_number = t.customer_number
WHERE t.transaction_id = p_transaction_id AND t.customer_number = p_customer_number
LIMIT 1;
END $$;

-- Function: getWallet
-- Prisma await: await getWalletByCustomerNumber(...) -> await prisma.wallet.findFirst(...)
-- Purpose: Fetch the active wallet for a customer.
CREATE OR REPLACE PROCEDURE "payments"."sp_get_wallet"(
    p_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT w.* FROM "payments"."wallet" w WHERE w.customer_number = p_customer_number AND w.is_active = true LIMIT 1;
END $$;

-- Function: getWalletBalance
-- Prisma await: await getWalletByCustomerNumber(...) -> await prisma.wallet.findFirst(...)
-- Purpose: Fetch wallet id, balance and currency for a customer.
CREATE OR REPLACE PROCEDURE "payments"."sp_get_wallet_balance"(
    p_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT w."walletId" AS wallet_id, w.balance, w.currency FROM "payments"."wallet" w WHERE w.customer_number = p_customer_number AND w.is_active = true LIMIT 1;
END $$;

-- Function: getWalletById
-- Prisma await: await getWalletByCustomerNumber(...) -> await prisma.wallet.findFirst(...)
-- Purpose: Fetch one active wallet by wallet id and customer number.
CREATE OR REPLACE PROCEDURE "payments"."sp_get_wallet_by_id"(
    p_wallet_id varchar,
    p_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT w.* FROM "payments"."wallet" w WHERE w."walletId" = p_wallet_id AND w.customer_number = p_customer_number AND w.is_active = true LIMIT 1;
END $$;

-- Function: getWalletStatus
-- Prisma await: await getWalletByCustomerNumber(...) -> await prisma.wallet.findFirst(...)
-- Purpose: Fetch wallet status information for a customer.
CREATE OR REPLACE PROCEDURE "payments"."sp_get_wallet_status"(
    p_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT w."walletId" AS wallet_id, w.status, w.is_active FROM "payments"."wallet" w WHERE w.customer_number = p_customer_number AND w.is_active = true LIMIT 1;
END $$;

-- Function: getWalletHistory
-- Prisma await: await prisma.walletTransaction.findMany(...)
-- Prisma await: await prisma.transaction.findMany(...)
-- Prisma await: await prisma.walletTransaction.count(...)
-- Purpose: Fetch paginated wallet history, optionally including Sukuk trades.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_wallet_history"(
    p_customer_number varchar,
    p_page integer DEFAULT 1,
    p_limit integer DEFAULT 10,
    p_type varchar DEFAULT NULL,
    p_start_date timestamp DEFAULT NULL,
    p_end_date timestamp DEFAULT NULL,
    p_include_trades boolean DEFAULT false,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT * FROM (
    SELECT w.id::varchar AS transaction_id, w.transaction_type::text AS type,
           w.amount, w.currency, w.status::text AS status,
           COALESCE(w.notes,w.transaction_type::text) AS description,
           w.created_at, 'WALLET'::text AS source
    FROM "payments"."wallet_transaction" w
    WHERE w.customer_number = p_customer_number
      AND (p_type IS NULL OR w.transaction_type::text = p_type)
      AND (p_start_date IS NULL OR w.created_at >= p_start_date)
      AND (p_end_date IS NULL OR w.created_at <= p_end_date)
    UNION ALL
    SELECT t.transaction_id::varchar, t.transaction_type::text, t.total_amount,
           t.currency, t.status::text,
           'Sukuk '||t.transaction_type::text||' - '||COALESCE(t.notes,''),
           t.transaction_date, 'TRADE'::text
    FROM "trade"."transaction" t
    WHERE p_include_trades AND t.customer_number = p_customer_number
) x
ORDER BY created_at DESC
OFFSET (GREATEST(p_page,1)-1)*p_limit
LIMIT p_limit;
END $$;

-- Function: requestWithdrawal
-- Prisma await: await getWalletByCustomerNumber(...) -> await prisma.wallet.findFirst(...)
-- Prisma await: await prisma.bankVerification.findFirst(...)
-- Prisma await: await tx.withdrawal.create(...)
-- Prisma await: await tx.wallet.update(...)
-- Prisma await: await tx.walletTransaction.create(...)
-- Purpose: Validate and create a withdrawal, debit wallet, and create wallet transaction.
CREATE OR REPLACE PROCEDURE "payments"."sp_request_withdrawal"(
    p_customer_number varchar,
    p_bank_verification_id integer,
    p_amount numeric,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_wallet wallet%ROWTYPE;
    v_bank bank_verification%ROWTYPE;
    v_before numeric(15,2);
    v_after numeric(15,2);
    v_id integer;
    v_withdrawal_id varchar(191);
BEGIN
    IF p_bank_verification_id IS NULL OR p_amount IS NULL OR p_amount<=0 THEN
    RAISE EXCEPTION 'Please provide bank verification ID and a positive amount';
    END IF;
    SELECT * INTO v_wallet
    FROM "payments"."wallet"
    WHERE customer_number=p_customer_number AND is_active=true
    FOR UPDATE;
    IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet not found';
    END IF;
    IF v_wallet.status::text<>'ACTIVE' THEN
    RAISE EXCEPTION 'Wallet is not active';
    END IF;
    IF v_wallet.balance<p_amount THEN
    RAISE EXCEPTION 'Insufficient wallet balance';
    END IF;
    SELECT * INTO v_bank
    FROM "kyc"."bank_verification"
    WHERE id=p_bank_verification_id AND customer_number=p_customer_number AND is_active=true AND account_status::text='APPROVED';
    IF NOT FOUND THEN
    RAISE EXCEPTION 'Bank account not found or not approved';
    END IF;
    v_before:=v_wallet.balance;
    v_after:=v_before-p_amount;
    v_withdrawal_id:='wd_'||md5(random()::text||clock_timestamp()::text);
    LOCK TABLE withdrawal IN SHARE ROW EXCLUSIVE MODE;
    SELECT COALESCE(MAX(id),0)+1 INTO v_id
    FROM "payments"."withdrawal";
    INSERT INTO "payments"."withdrawal"(id,withdrawal_id,customer_number,bank_verification_id,amount,currency,wallet_balance_before,wallet_balance_after,status,requested_at,is_active,created_at,updated_at)
    VALUES(v_id,v_withdrawal_id,p_customer_number,p_bank_verification_id,p_amount,v_wallet.currency,v_before,v_after,'PENDING',clock_timestamp(),true,clock_timestamp(),clock_timestamp());
    UPDATE "payments"."wallet" SET balance=v_after,last_transaction=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=v_wallet.id;
    INSERT INTO "payments"."wallet_transaction"(id,customer_number,transaction_type,amount,currency,wallet_balance_before,wallet_balance_after,status,reference_id,notes,created_at,updated_at)
    VALUES('wtx_'||md5(random()::text||clock_timestamp()::text),p_customer_number,'WITHDRAWAL',p_amount,v_wallet.currency,v_before,v_after,'PENDING',v_withdrawal_id,'Withdrawal request to '||v_bank.bank_name||' - '||v_bank.account_number,clock_timestamp(),clock_timestamp());
    OPEN p_cursor FOR
    SELECT v_withdrawal_id AS withdrawal_id, p_amount AS amount, v_wallet.currency AS currency, 'PENDING'::text AS status, v_bank.bank_name, v_bank.account_number, v_bank.holder_name;
    RETURN;
END $$;

-- Function: getWithdrawalHistory
-- Prisma await: await prisma.withdrawal.findMany(...)
-- Prisma await: await prisma.withdrawal.count(...)
-- Purpose: Fetch paginated withdrawal history for one customer.
CREATE OR REPLACE PROCEDURE "kyc"."sp_get_withdrawal_history"(
    p_customer_number varchar,
    p_status varchar DEFAULT NULL,
    p_limit integer DEFAULT 10,
    p_offset integer DEFAULT 0,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT w.*, b.bank_name, b.account_number, b.holder_name, b.branch_name,
       count(*) OVER() AS total_count
FROM "payments"."withdrawal" w
JOIN "kyc"."bank_verification" b ON b.id = w.bank_verification_id
WHERE w.customer_number = p_customer_number
  AND w.is_active = true
  AND (p_status IS NULL OR w.status::text = p_status)
ORDER BY w.requested_at DESC
LIMIT p_limit OFFSET p_offset;
END $$;

-- Function: getWithdrawalById
-- Prisma await: await prisma.withdrawal.findFirst(...)
-- Purpose: Fetch one withdrawal with bank-account reference columns.
CREATE OR REPLACE PROCEDURE "kyc"."sp_get_withdrawal_by_id"(
    p_customer_number varchar,
    p_withdrawal_id varchar,
    p_role varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT w.*, b.bank_name, b.account_number, b.holder_name, b.branch_name
FROM "payments"."withdrawal" w
JOIN "kyc"."bank_verification" b ON b.id = w.bank_verification_id
WHERE w.withdrawal_id = p_withdrawal_id
  AND w.is_active = true
  AND (w.customer_number = p_customer_number OR p_role IN ('ADMIN','SUPER_ADMIN'))
LIMIT 1;
END $$;

-- Function: cancelWithdrawal
-- Prisma await: await prisma.withdrawal.findFirst(...)
-- Prisma await: await getWalletByCustomerNumber(...) -> await prisma.wallet.findFirst(...)
-- Prisma await: await tx.withdrawal.update(...)
-- Prisma await: await tx.walletTransaction.updateMany(...)
-- Prisma await: await tx.wallet.update(...)
-- Prisma await: await tx.walletTransaction.create(...)
-- Purpose: Cancel a pending withdrawal and refund the wallet.
CREATE OR REPLACE PROCEDURE "payments"."sp_cancel_withdrawal"(
    p_customer_number varchar,
    p_withdrawal_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_wd withdrawal%ROWTYPE;
    v_w wallet%ROWTYPE;
    v_after numeric(15,2);
BEGIN
    SELECT * INTO v_wd
    FROM "payments"."withdrawal"
    WHERE withdrawal_id=p_withdrawal_id AND customer_number=p_customer_number AND is_active=true
    FOR UPDATE;
    IF NOT FOUND THEN
    RAISE EXCEPTION 'Withdrawal not found';
    END IF;
    IF v_wd.status::text<>'PENDING' THEN
    RAISE EXCEPTION 'Cannot cancel this withdrawal';
    END IF;
    SELECT * INTO v_w
    FROM "payments"."wallet"
    WHERE customer_number=p_customer_number AND is_active=true
    FOR UPDATE;
    IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet not found';
    END IF;
    v_after:=v_w.balance+v_wd.amount;
    UPDATE "payments"."withdrawal" SET status='CANCELLED',admin_notes='Cancelled by user',updated_at=clock_timestamp()
    WHERE id=v_wd.id;
    UPDATE "payments"."wallet_transaction" SET status='CANCELLED',updated_at=clock_timestamp()
    WHERE reference_id=p_withdrawal_id AND transaction_type::text='WITHDRAWAL';
    UPDATE "payments"."wallet" SET balance=v_after,last_transaction=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=v_w.id;
    INSERT INTO "payments"."wallet_transaction"(id,customer_number,transaction_type,amount,currency,wallet_balance_before,wallet_balance_after,status,reference_id,notes,created_at,updated_at)
    VALUES('wtx_'||md5(random()::text||clock_timestamp()::text),p_customer_number,'CREDIT',v_wd.amount,v_wd.currency,v_w.balance,v_after,'COMPLETED',p_withdrawal_id,'Withdrawal refund - cancelled by user',clock_timestamp(),clock_timestamp());
    OPEN p_cursor FOR
    SELECT p_withdrawal_id AS withdrawal_id, 'CANCELLED'::text AS status, v_after AS wallet_balance_after;
    RETURN;
END $$;

-- Function: updateWithdrawalStatus
-- Prisma await: await prisma.withdrawal.findFirst(...)
-- Prisma await: await getWalletByCustomerNumber(...) -> await prisma.wallet.findFirst(...)
-- Prisma await: await tx.withdrawal.update(...)
-- Prisma await: await tx.walletTransaction.updateMany(...)
-- Prisma await: await tx.wallet.update(...)
-- Prisma await: await tx.walletTransaction.create(...)
-- Prisma await: await prisma.withdrawal.update(...)
-- Prisma await: await prisma.walletTransaction.updateMany(...)
-- Purpose: Admin update of withdrawal status with refund handling when required.
CREATE OR REPLACE PROCEDURE "payments"."sp_update_withdrawal_status"(
    p_withdrawal_id varchar,
    p_status varchar,
    p_admin_notes text DEFAULT NULL,
    p_transaction_reference varchar DEFAULT NULL,
    p_failed_reason text DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_wd withdrawal%ROWTYPE;
    v_w wallet%ROWTYPE;
    v_after numeric(15,2);
    v_refund boolean;
BEGIN
    IF p_status NOT IN('PENDING','PROCESSING','COMPLETED','FAILED','CANCELLED') THEN
    RAISE EXCEPTION 'Invalid status';
    END IF;
    SELECT * INTO v_wd
    FROM "payments"."withdrawal"
    WHERE withdrawal_id=p_withdrawal_id AND is_active=true
    FOR UPDATE;
    IF NOT FOUND THEN
    RAISE EXCEPTION 'Withdrawal not found';
    END IF;
    v_refund:=p_status IN('FAILED','CANCELLED') AND v_wd.status::text NOT IN('FAILED','CANCELLED');
    UPDATE "payments"."withdrawal" SET status=p_status::withdrawal_status,admin_notes=COALESCE(p_admin_notes,admin_notes),transaction_reference=COALESCE(p_transaction_reference,transaction_reference),processed_at=CASE WHEN p_status='PROCESSING' THEN
    COALESCE(processed_at,clock_timestamp())
    ELSE
    processed_at
    END,completed_at=CASE WHEN p_status='COMPLETED' THEN
    COALESCE(completed_at,clock_timestamp())
    ELSE
    completed_at
    END,failed_reason=CASE WHEN p_status='FAILED' THEN
    COALESCE(p_failed_reason,'Failed by admin')
    ELSE
    failed_reason
    END,updated_at=clock_timestamp()
    WHERE id=v_wd.id;
    UPDATE "payments"."wallet_transaction" SET status=p_status::status_enum,updated_at=clock_timestamp()
    WHERE reference_id=p_withdrawal_id AND transaction_type::text='WITHDRAWAL';
    IF v_refund THEN
    SELECT * INTO v_w
    FROM "payments"."wallet"
    WHERE customer_number=v_wd.customer_number AND is_active=true
    FOR UPDATE;
    IF FOUND THEN
    v_after:=v_w.balance+v_wd.amount;
    UPDATE "payments"."wallet" SET balance=v_after,last_transaction=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=v_w.id;
    INSERT INTO "payments"."wallet_transaction"(id,customer_number,transaction_type,amount,currency,wallet_balance_before,wallet_balance_after,status,reference_id,notes,created_at,updated_at)
    VALUES('wtx_'||md5(random()::text||clock_timestamp()::text),v_wd.customer_number,'CREDIT',v_wd.amount,v_wd.currency,v_w.balance,v_after,'COMPLETED',p_withdrawal_id,'Withdrawal refund - marked '||p_status||' by admin',clock_timestamp(),clock_timestamp());
    END IF;
    END IF;
    OPEN p_cursor FOR
    SELECT p_withdrawal_id AS withdrawal_id, p_status AS status;
    RETURN;
END $$;

-- Function: getAllWithdrawals
-- Prisma await: await prisma.withdrawal.count(...)
-- Prisma await: await prisma.withdrawal.findMany(...)
-- Prisma await: await prisma.withdrawal.count(...) [status counts]
-- Purpose: Fetch admin withdrawal list using filters and pagination/export mode.
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
CREATE OR REPLACE PROCEDURE "kyc"."sp_get_user_withdrawals"(
    p_customer_number varchar,
    p_status varchar DEFAULT NULL,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT w.*, b.bank_name, b.account_number, b.holder_name, b.branch_name,
       count(*) OVER() AS total_count
FROM "payments"."withdrawal" w
JOIN "kyc"."bank_verification" b ON b.id = w.bank_verification_id
WHERE w.customer_number = p_customer_number
  AND w.is_active = true
  AND (p_status IS NULL OR w.status::text = p_status)
ORDER BY w.requested_at DESC
LIMIT p_limit OFFSET p_offset;
END $$;

-- Function: creditWalletManually
-- Prisma await: await getWalletByCustomerNumber(...) -> await prisma.wallet.findFirst(...)
-- Prisma await: await tx.wallet.update(...)
-- Prisma await: await tx.walletTransaction.create(...)
-- Purpose: Credit a customer wallet manually and create audit wallet transaction.
CREATE OR REPLACE PROCEDURE "payments"."sp_credit_wallet_manually"(
    p_customer_number varchar,
    p_amount numeric,
    p_notes text,
    p_admin_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_w wallet%ROWTYPE;
    v_after numeric(15,2);
    v_id varchar(191);
BEGIN
    IF p_customer_number IS NULL OR p_amount IS NULL OR p_amount<=0 THEN
    RAISE EXCEPTION 'customer_number and positive amount are required';
    END IF;
    SELECT * INTO v_w
    FROM "payments"."wallet"
    WHERE customer_number=p_customer_number AND is_active=true
    FOR UPDATE;
    IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet not found';
    END IF;
    v_after:=v_w.balance+p_amount;
    v_id:='wtx_'||md5(random()::text||clock_timestamp()::text);
    UPDATE "payments"."wallet" SET balance=v_after,last_transaction=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=v_w.id;
    INSERT INTO "payments"."wallet_transaction"(id,customer_number,transaction_type,amount,currency,wallet_balance_before,wallet_balance_after,status,processed_by,notes,created_at,updated_at)
    VALUES(v_id,p_customer_number,'CREDIT',p_amount,'USD',v_w.balance,v_after,'COMPLETED',p_admin_customer_number,COALESCE(p_notes,'Manual deposit by admin '||p_admin_customer_number),clock_timestamp(),clock_timestamp());
    OPEN p_cursor FOR
    SELECT p_customer_number AS customer_number, p_amount AS amount, 'USD'::text AS currency, v_w.balance AS wallet_balance_before, v_after AS wallet_balance_after, v_id AS transaction_id;
    RETURN;
END $$;

-- Function: previewCSV
-- Prisma await: await prisma.$transaction(...) -> await tx.depositCSV.create(...)
-- Purpose: Store one previewed deposit CSV row and return its generated batch summary.
 
CREATE OR REPLACE PROCEDURE "payments"."sp_preview_deposit_csv"(
    p_customer_number varchar,
    p_period_from varchar,
    p_period_to varchar,
    p_account_number varchar,
    p_currency varchar,
    p_portfolio varchar,
    p_portfolio_name varchar,
    p_opening_balance numeric,
    p_transaction_date timestamp,
    p_value_date timestamp,
    p_transaction_type varchar,
    p_description text,
    p_amount_credited numeric,
    p_closing_balance numeric,
    p_reference_number varchar,
    p_transaction_reference text,
    p_is_valid boolean,
    p_is_duplicate boolean,
    p_validation_error text,
    p_admin_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_batch varchar(191):='batch-'||floor(extract(epoch
    FROM clock_timestamp())*1000)::bigint||'-'||substr(md5(random()::text),1,9);
BEGIN
    INSERT INTO "payments"."deposit_csv"(id,batch_id,customer_number,period_from,period_to,account_number,currency,portfolio,portfolio_name,opening_balance,transaction_date,value_date,transaction_type,description,amount_credited,closing_balance,reference_no,transaction_reference,status,is_valid,is_duplicate,validation_error,processed_by,created_at,updated_at)
    VALUES('dcsv_'||md5(random()::text||clock_timestamp()::text),v_batch,p_customer_number,p_period_from,p_period_to,p_account_number,COALESCE(p_currency,'USD'),p_portfolio,p_portfolio_name,p_opening_balance,p_transaction_date,p_value_date,p_transaction_type,p_description,COALESCE(p_amount_credited,0),p_closing_balance,p_reference_number,p_transaction_reference,'PENDING',COALESCE(p_is_valid,true),COALESCE(p_is_duplicate,false),p_validation_error,p_admin_customer_number,clock_timestamp(),clock_timestamp());
    OPEN p_cursor FOR
    SELECT v_batch AS batch_id, 1 AS inserted_count;
    RETURN;
END $$;

-- Function: processApprovedCSV
-- Prisma await: await prisma.depositCSV.updateMany(...)
-- Prisma await: await prisma.depositCSV.findMany(...)
-- Prisma await: await processDeposits(...)
-- Prisma await: await prisma.depositCSV.update(...)
-- Purpose: Process one approved CSV deposit record and return its processing result.

CREATE OR REPLACE PROCEDURE "payments"."sp_process_approved_csv"(
    p_transaction_id varchar,
    p_admin_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_record deposit_csv%ROWTYPE;
    v_w wallet%ROWTYPE;
    v_after numeric(15,2);
    v_ok integer:=0;
    v_failed integer:=0;
BEGIN
    SELECT * INTO v_record
    FROM "payments"."deposit_csv"
    WHERE id=p_transaction_id AND status::text='PENDING'
    FOR UPDATE;
    IF NOT FOUND THEN
    v_failed:=v_failed+1;
    ELSE
    UPDATE "payments"."deposit_csv" SET status='APPROVED',processed_by=p_admin_customer_number,processed_at=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=v_record.id;
    SELECT * INTO v_w
    FROM "payments"."wallet"
    WHERE customer_number=v_record.customer_number AND is_active=true
    FOR UPDATE;
    IF FOUND THEN
    v_after:=v_w.balance+v_record.amount_credited;
    UPDATE "payments"."wallet" SET balance=v_after,last_transaction=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=v_w.id;
    INSERT INTO "payments"."wallet_transaction"(id,customer_number,transaction_type,amount,currency,wallet_balance_before,wallet_balance_after,status,notes,processed_by,reference_id,created_at,updated_at)
    VALUES('wtx_'||md5(random()::text||clock_timestamp()::text),v_record.customer_number,'DEPOSIT',v_record.amount_credited,v_record.currency,v_w.balance,v_after,'COMPLETED','Bank deposit - '||COALESCE(v_record.description,''),p_admin_customer_number,v_record.transaction_reference,clock_timestamp(),clock_timestamp());
    v_ok:=v_ok+1;
    ELSE
    UPDATE "payments"."deposit_csv" SET status='REJECTED',rejection_reason='Wallet not found',processed_at=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=v_record.id;
    v_failed:=v_failed+1;
    END IF;
    END IF;
    OPEN p_cursor FOR
    SELECT v_ok AS successful, v_failed AS failed, 1 AS total;
    RETURN;
END $$;

-- Function: processBankStatementCSV
-- Prisma await: await processDeposits(...)
-- Purpose: Process one bank-statement deposit record and return its processing result.

CREATE OR REPLACE PROCEDURE "payments"."sp_process_bank_statement_csv"(
    p_customer_number varchar,
    p_amount numeric,
    p_currency varchar,
    p_transaction_date timestamp,
    p_description text,
    p_transaction_reference text,
    p_reference_number varchar,
    p_admin_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_w wallet%ROWTYPE;
    v_after numeric;
    v_ok integer:=0;
    v_failed integer:=0;
BEGIN
    SELECT * INTO v_w
    FROM "payments"."wallet"
    WHERE customer_number=p_customer_number AND is_active=true
    FOR UPDATE;
    IF FOUND AND p_amount>0 AND NOT EXISTS(
    SELECT 1
    FROM "payments"."wallet_transaction"
    WHERE customer_number=p_customer_number AND transaction_type::text='DEPOSIT' AND amount=p_amount AND created_at::date=p_transaction_date::date)THEN
    v_after:=v_w.balance+p_amount;
    UPDATE "payments"."wallet" SET balance=v_after,last_transaction=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=v_w.id;
    INSERT INTO "payments"."wallet_transaction"(id,customer_number,transaction_type,amount,currency,wallet_balance_before,wallet_balance_after,status,notes,processed_by,reference_id,created_at,updated_at)
    VALUES('wtx_'||md5(random()::text||clock_timestamp()::text),p_customer_number,'DEPOSIT',p_amount,COALESCE(p_currency,'USD'),v_w.balance,v_after,'COMPLETED','Bank deposit - '||COALESCE(p_description,''),p_admin_customer_number,COALESCE(p_transaction_reference,p_reference_number),clock_timestamp(),clock_timestamp());
    v_ok:=v_ok+1;
    ELSE
    v_failed:=v_failed+1;
    END IF;
    OPEN p_cursor FOR
    SELECT v_ok AS successful, v_failed AS failed, 1 AS total;
    RETURN;
END $$;

-- Function: getDepositCSVByBatch
-- Prisma await: await prisma.depositCSV.findMany(...)
-- Purpose: Fetch deposit CSV rows, optionally filtered by batch id.
CREATE OR REPLACE PROCEDURE "payments"."sp_get_deposit_csv_by_batch"(
    p_batch_id varchar DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT d.* FROM "payments"."deposit_csv" d WHERE p_batch_id IS NULL OR d.batch_id = p_batch_id ORDER BY d.created_at;
END $$;

-- Function: approveDepositCSV
-- Prisma await: await prisma.depositCSV.findUnique(...)
-- Prisma await: await prisma.depositCSV.update(...)
-- Prisma await: await processDeposits(...)
-- Purpose: Approve one deposit CSV row and credit the customer wallet.
CREATE OR REPLACE PROCEDURE "payments"."sp_approve_deposit_csv"(
    p_id varchar,
    p_admin_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_d deposit_csv%ROWTYPE;
    v_w wallet%ROWTYPE;
    v_after numeric(15,2);
BEGIN
    SELECT * INTO v_d
    FROM "payments"."deposit_csv"
    WHERE id=p_id
    FOR UPDATE;
    IF NOT FOUND THEN
    RAISE EXCEPTION 'Deposit CSV record not found';
    END IF;
    IF v_d.status::text<>'PENDING'THEN
    RAISE EXCEPTION 'Record is already %',v_d.status;
    END IF;
    SELECT * INTO v_w
    FROM "payments"."wallet"
    WHERE customer_number=v_d.customer_number AND is_active=true
    FOR UPDATE;
    IF NOT FOUND THEN
    UPDATE "payments"."deposit_csv" SET status='REJECTED',rejection_reason='Wallet not found',processed_by=p_admin_customer_number,processed_at=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=p_id;
    RAISE EXCEPTION 'Wallet not found';
    END IF;
    v_after:=v_w.balance+v_d.amount_credited;
    UPDATE "payments"."wallet" SET balance=v_after,last_transaction=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=v_w.id;
    INSERT INTO "payments"."wallet_transaction"(id,customer_number,transaction_type,amount,currency,wallet_balance_before,wallet_balance_after,status,notes,processed_by,reference_id,created_at,updated_at)
    VALUES('wtx_'||md5(random()::text||clock_timestamp()::text),v_d.customer_number,'DEPOSIT',v_d.amount_credited,v_d.currency,v_w.balance,v_after,'COMPLETED','Bank deposit - '||COALESCE(v_d.description,''),p_admin_customer_number,v_d.transaction_reference,clock_timestamp(),clock_timestamp());
    UPDATE "payments"."deposit_csv" SET status='APPROVED',processed_by=p_admin_customer_number,processed_at=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=p_id;
    OPEN p_cursor FOR
    SELECT d.* FROM "payments"."deposit_csv" d WHERE d.id = p_id;
    RETURN;
END $$;

-- Function: rejectDepositCSV
-- Prisma await: await prisma.depositCSV.findUnique(...)
-- Prisma await: await prisma.depositCSV.update(...)
-- Prisma await: await getWalletByCustomerNumber(...) -> await prisma.wallet.findFirst(...)
-- Prisma await: await prisma.walletTransaction.create(...)
-- Purpose: Reject one deposit CSV row and create failed wallet-transaction audit.
CREATE OR REPLACE PROCEDURE "payments"."sp_reject_deposit_csv"(
    p_id varchar,
    p_reason text,
    p_admin_customer_number varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_d deposit_csv%ROWTYPE;
    v_balance numeric:=0;
BEGIN
    SELECT * INTO v_d
    FROM "payments"."deposit_csv"
    WHERE id=p_id
    FOR UPDATE;
    IF NOT FOUND THEN
    RAISE EXCEPTION 'Deposit CSV record not found';
    END IF;
    UPDATE "payments"."deposit_csv" SET status='REJECTED',rejection_reason=p_reason,processed_by=p_admin_customer_number,processed_at=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=p_id;
    SELECT balance INTO v_balance
    FROM "payments"."wallet"
    WHERE customer_number=v_d.customer_number AND is_active=true
    LIMIT 1;
    INSERT INTO "payments"."wallet_transaction"(id,customer_number,transaction_type,amount,currency,wallet_balance_before,wallet_balance_after,status,notes,processed_by,reference_id,created_at,updated_at)
    VALUES('wtx_'||md5(random()::text||clock_timestamp()::text),v_d.customer_number,'DEPOSIT',v_d.amount_credited,v_d.currency,COALESCE(v_balance,0),COALESCE(v_balance,0),'FAILED','Bank deposit rejected - '||COALESCE(p_reason,''),p_admin_customer_number,v_d.transaction_reference,clock_timestamp(),clock_timestamp());
    OPEN p_cursor FOR
    SELECT d.* FROM "payments"."deposit_csv" d WHERE d.id = p_id;
    RETURN;
END $$;
-- Function: uploadExcelAndCreateInventory
-- Prisma await: await prisma.sukuk_inventory.findUnique/findFirst(...)
-- Prisma await: await prisma.sukuk_inventory.update/create(...)
-- Prisma await: await createInventoryAuditLog(...) -> await prisma.inventoryAuditLog.create(...)
-- Purpose: Create/update one Sukuk inventory row from Excel data and write its audit row.

CREATE OR REPLACE PROCEDURE "trade"."sp_upload_excel_and_create_inventory"(
    p_inventory_id varchar,
    p_name varchar,
    p_issuer varchar,
    p_issuer_logo varchar,
    p_country varchar,
    p_sector text,
    p_type text,
    p_ytm double precision,
    p_ytc double precision,
    p_profit_rate double precision,
    p_maturity_date timestamp,
    p_issue_date timestamp,
    p_bid_price double precision,
    p_ask_price double precision,
    p_min_fractional_investment double precision,
    p_fractional_quantity double precision,
    p_full_size_ticket double precision,
    p_face_value double precision,
    p_isin varchar,
    p_currency varchar,
    p_quantity integer,
    p_description text,
    p_is_active boolean,
    p_changed_by_id varchar,
    p_changed_by_name varchar,
    p_change_reason text,
    p_batch_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_existing sukuk_inventory%ROWTYPE;
    v_pk integer;
    v_created integer:=0;
    v_updated integer:=0;
    v_after sukuk_inventory%ROWTYPE;
BEGIN
    SELECT * INTO v_existing
    FROM "trade"."sukuk_inventory"
    WHERE (p_inventory_id IS NOT NULL AND inventory_id=p_inventory_id) OR (p_isin IS NOT NULL AND isin=p_isin)
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
        UPDATE "trade"."sukuk_inventory" SET 
            name=COALESCE(p_name,name),
            issuer=COALESCE(p_issuer,issuer),
            "issuerLogo"=COALESCE(p_issuer_logo,"issuerLogo"),
            country=COALESCE(p_country,country),
            sector=COALESCE(p_sector,sector),
            type=COALESCE(p_type,type),
            ytm=COALESCE(p_ytm,ytm),
            ytc=COALESCE(p_ytc,ytc),
            "profitRate"=COALESCE(p_profit_rate,"profitRate"),
            "maturityDate"=COALESCE(p_maturity_date,"maturityDate"),
            "issueDate"=COALESCE(p_issue_date,"issueDate"),
            "bidPrice"=COALESCE(p_bid_price,"bidPrice"),
            "askPrice"=COALESCE(p_ask_price,"askPrice"),
            "minFractionalInvestment"=COALESCE(p_min_fractional_investment,"minFractionalInvestment"),
            "fractionalQuantity"=COALESCE(p_fractional_quantity,"fractionalQuantity"),
            "fullSizeTicket"=COALESCE(p_full_size_ticket,"fullSizeTicket"),
            "faceValue"=COALESCE(p_face_value,"faceValue"),
            currency=COALESCE(p_currency,currency),
            quantity=COALESCE(p_quantity,quantity),
            description=COALESCE(p_description,description),
            is_active=COALESCE(p_is_active,is_active),
            updated_at=clock_timestamp()
        WHERE id=v_existing.id;

        v_updated:=v_updated+1;

        SELECT i.* INTO v_after
        FROM "trade"."sukuk_inventory" i
        WHERE id=v_existing.id;
    ELSE
        LOCK TABLE sukuk_inventory IN SHARE ROW EXCLUSIVE MODE;
        
        SELECT COALESCE(MAX(id),0)+1 INTO v_pk
        FROM "trade"."sukuk_inventory";
        
        INSERT INTO "trade"."sukuk_inventory"(id,inventory_id,name,issuer,"issuerLogo",country,sector,type,ytm,ytc,"profitRate","maturityDate","issueDate","bidPrice","askPrice","minFractionalInvestment","fractionalQuantity","fullSizeTicket","faceValue",isin,currency,quantity,description,is_active,created_at,updated_at)
        VALUES(v_pk,p_inventory_id,p_name,p_issuer,p_issuer_logo,p_country,p_sector,p_type,COALESCE(p_ytm,0),p_ytc,COALESCE(p_profit_rate,0),p_maturity_date,p_issue_date,p_bid_price,p_ask_price,p_min_fractional_investment,p_fractional_quantity,p_full_size_ticket,p_face_value,p_isin,COALESCE(p_currency,'USD'),COALESCE(p_quantity,0),p_description,COALESCE(p_is_active,true),clock_timestamp(),clock_timestamp());
        
        v_created:=v_created+1;
        
        SELECT i.* INTO v_after
        FROM "trade"."sukuk_inventory" i
        WHERE id=v_pk;
    END IF;

    LOCK TABLE inventory_audit_log IN SHARE ROW EXCLUSIVE MODE;
    
    SELECT COALESCE(MAX(id),0)+1 INTO v_pk
    FROM "trade"."inventory_audit_log";
    
    INSERT INTO "trade"."inventory_audit_log"(id,audit_id,inventory_id,change_type,changed_by_id,changed_by_name,changed_at,data_before,data_after,change_reason,batch_id,created_at)
    VALUES(
        v_pk,
        'audit_'||md5(random()::text||clock_timestamp()::text),
        v_after.inventory_id,
        -- Fixed Enum Type Cast
        (CASE WHEN v_existing.id IS NULL THEN 'EXCEL_UPLOAD_CREATE' ELSE 'EXCEL_UPLOAD_UPDATE' END)::audit_change_type,
        p_changed_by_id,
        p_changed_by_name,
        clock_timestamp(),
        CASE WHEN v_existing.id IS NULL THEN NULL ELSE row_to_json(v_existing)::jsonb END,
        row_to_json(v_after)::jsonb,
        p_change_reason,
        p_batch_id,
        clock_timestamp()
    );

    OPEN p_cursor FOR
    SELECT v_created AS created, v_updated AS updated, 1 AS total;
    RETURN;
END $$;


-- Function: createBulkInventory
-- Prisma await: await prisma.sukuk_inventory.findUnique/findFirst(...)
-- Prisma await: await prisma.sukuk_inventory.update/create(...)
-- Purpose: Create/update one Sukuk inventory row from typed input parameters.

CREATE OR REPLACE PROCEDURE "trade"."sp_create_bulk_inventory"(
    p_inventory_id varchar,
    p_name varchar,
    p_issuer varchar,
    p_ytm double precision,
    p_profit_rate double precision,
    p_bid_price double precision,
    p_ask_price double precision,
    p_isin varchar,
    p_currency varchar,
    p_quantity integer,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_existing sukuk_inventory%ROWTYPE;
    v_pk integer;
    v_created integer:=0;
    v_updated integer:=0;
BEGIN
    SELECT * INTO v_existing
    FROM "trade"."sukuk_inventory"
    WHERE (p_inventory_id IS NOT NULL AND inventory_id=p_inventory_id)OR(p_isin IS NOT NULL AND isin=p_isin)
    LIMIT 1
    FOR UPDATE;
    IF FOUND THEN
    UPDATE "trade"."sukuk_inventory" SET name=COALESCE(p_name,name),issuer=COALESCE(p_issuer,issuer),ytm=COALESCE(p_ytm,ytm),"profitRate"=COALESCE(p_profit_rate,"profitRate"),"bidPrice"=COALESCE(p_bid_price,"bidPrice"),"askPrice"=COALESCE(p_ask_price,"askPrice"),currency=COALESCE(p_currency,currency),quantity=COALESCE(p_quantity,quantity),updated_at=clock_timestamp()
    WHERE id=v_existing.id;
    v_updated:=v_updated+1;
    ELSE
    LOCK TABLE sukuk_inventory IN SHARE ROW EXCLUSIVE MODE;
    SELECT COALESCE(MAX(id),0)+1 INTO v_pk
    FROM "trade"."sukuk_inventory";
    INSERT INTO "trade"."sukuk_inventory"(id,inventory_id,name,issuer,ytm,"profitRate","bidPrice","askPrice",isin,currency,quantity,is_active,created_at,updated_at)
    VALUES(v_pk,p_inventory_id,p_name,p_issuer,COALESCE(p_ytm,0),COALESCE(p_profit_rate,0),p_bid_price,p_ask_price,p_isin,COALESCE(p_currency,'USD'),COALESCE(p_quantity,0),true,clock_timestamp(),clock_timestamp());
    v_created:=v_created+1;
    END IF;
    OPEN p_cursor FOR
    SELECT v_created AS created, v_updated AS updated, 1 AS total;
    RETURN;
END $$;

-- Function: getAllInventory
-- Prisma await: await prisma.sukuk_inventory.count(...)
-- Prisma await: await prisma.sukuk_inventory.findMany(...)
-- Purpose: Fetch paginated Sukuk inventory with filters.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_all_inventory"(
    p_page integer DEFAULT 1,
    p_limit integer DEFAULT 10,
    p_sector varchar DEFAULT NULL,
    p_currency varchar DEFAULT NULL,
    p_search varchar DEFAULT NULL,
    p_is_active varchar DEFAULT 'true',
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT i.*, count(*) OVER() AS total_count
FROM "trade"."sukuk_inventory" i
WHERE (p_is_active = 'all' OR i.is_active = (p_is_active = 'true'))
  AND (p_sector IS NULL OR i.sector = p_sector)
  AND (p_currency IS NULL OR i.currency = p_currency)
  AND (p_search IS NULL OR btrim(p_search) = '' OR i.name ILIKE '%'||btrim(p_search)||'%' OR COALESCE(i.isin,'') ILIKE '%'||btrim(p_search)||'%')
ORDER BY i.is_coming_soon ASC, i.created_at ASC
OFFSET (GREATEST(p_page,1)-1)*p_limit
LIMIT p_limit;
END $$;

-- Function: getInventoryById
-- Prisma await: await prisma.sukuk_inventory.findFirst(...)
-- Prisma await: await prisma.sukukCallEvent.findFirst(...)
-- Purpose: Fetch one inventory row together with calculated next call date.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_inventory_by_id"(
    p_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT i.*, COALESCE((
    SELECT e.call_date
    FROM "trade"."sukuk_call_event" e
    WHERE e.inventory_id = i.inventory_id
      AND e.status::text = 'PENDING'
      AND e.call_date > current_date
    ORDER BY e.call_date
    LIMIT 1
), i."callDate"::date) AS next_call_date
FROM "trade"."sukuk_inventory" i
WHERE i.inventory_id = p_id
LIMIT 1;
END $$;

-- Function: getUpcomingCallEvents
-- Prisma await: await prisma.sukuk_inventory.findFirst(...)
-- Prisma await: await prisma.sukukCallEvent.findMany(...)
-- Purpose: Fetch upcoming/pending call events for an inventory item.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_upcoming_call_events"(
    p_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT e.event_id, e.call_date, e.event_type, e.status
FROM "trade"."sukuk_call_event" e
WHERE e.inventory_id = p_id
  AND EXISTS (SELECT 1 FROM "trade"."sukuk_inventory" i WHERE i.inventory_id = p_id)
ORDER BY e.call_date;
END $$;

-- Function: updateInventory
-- Prisma await: await prisma.sukuk_inventory.findFirst(...)
-- Prisma await: await prisma.sukuk_inventory.update(...)
-- Prisma await: await prisma.sukukCallEvent.findMany(...)
-- Prisma await: await prisma.sukukInvestmentCredit.deleteMany(...)
-- Prisma await: await prisma.sukukCallEvent.deleteMany(...)
-- Purpose: Update Sukuk inventory and reset pending schedule rows when schedule fields change.
CREATE OR REPLACE PROCEDURE "trade"."sp_update_inventory"(
    INOUT p_cursor refcursor, -- १ल्या क्रमांकावर आणले (No DEFAULT here)
    p_id varchar,
    p_user_id varchar,
    p_name varchar DEFAULT NULL,
    p_issuer varchar DEFAULT NULL,
    p_issuer_logo varchar DEFAULT NULL,
    p_country varchar DEFAULT NULL,
    p_sector text DEFAULT NULL,
    p_type text DEFAULT NULL,
    p_ytm double precision DEFAULT NULL,
    p_profit_rate double precision DEFAULT NULL,
    p_profit_frequency profit_frequency_enum DEFAULT NULL,
    p_maturity_date timestamp DEFAULT NULL,
    p_issue_date timestamp DEFAULT NULL,
    p_call_date timestamp DEFAULT NULL,
    p_bid_price double precision DEFAULT NULL,
    p_ask_price double precision DEFAULT NULL,
    p_min_fractional_investment double precision DEFAULT NULL,
    p_full_size_ticket double precision DEFAULT NULL,
    p_accrued_interest double precision DEFAULT NULL,
    p_isin varchar DEFAULT NULL,
    p_currency varchar DEFAULT NULL,
    p_fractional_quantity double precision DEFAULT NULL,
    p_description text DEFAULT NULL,
    p_factsheet_url varchar DEFAULT NULL,
    p_prospectus_url varchar DEFAULT NULL,
    p_quantity integer DEFAULT NULL,
    p_is_active boolean DEFAULT NULL,
    p_is_coming_soon boolean DEFAULT NULL,
    p_discount_percentage numeric DEFAULT NULL,
    p_discount_updated_at timestamp DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    v_old sukuk_inventory%ROWTYPE;
    v_schedule boolean;
BEGIN
    SELECT * INTO v_old
    FROM "trade"."sukuk_inventory"
    WHERE inventory_id=p_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory not found';
    END IF;
    
    v_schedule:=p_issue_date IS NOT NULL OR p_maturity_date IS NOT NULL
        OR p_call_date IS NOT NULL OR p_profit_frequency IS NOT NULL;
        
    UPDATE "trade"."sukuk_inventory" SET
        name=COALESCE(p_name,name),
        issuer=COALESCE(p_issuer,issuer),
        "issuerLogo"=COALESCE(p_issuer_logo,"issuerLogo"),
        country=COALESCE(p_country,country),
        sector=COALESCE(p_sector,sector),
        type=COALESCE(p_type,type),
        ytm=COALESCE(p_ytm,ytm),
        "profitRate"=COALESCE(p_profit_rate,"profitRate"),
        "profitFrequency"=COALESCE(p_profit_frequency,"profitFrequency"),
        "maturityDate"=COALESCE(p_maturity_date,"maturityDate"),
        "issueDate"=COALESCE(p_issue_date,"issueDate"),
        "callDate"=COALESCE(p_call_date,"callDate"),
        "bidPrice"=COALESCE(p_bid_price,"bidPrice"),
        "askPrice"=COALESCE(p_ask_price,"askPrice"),
        "minFractionalInvestment"=COALESCE(p_min_fractional_investment,"minFractionalInvestment"),
        "fullSizeTicket"=COALESCE(p_full_size_ticket,"fullSizeTicket"),
        "accruedInterest"=COALESCE(p_accrued_interest,"accruedInterest"),
        isin=COALESCE(p_isin,isin),
        currency=COALESCE(p_currency,currency),
        "fractionalQuantity"=COALESCE(p_fractional_quantity,"fractionalQuantity"),
        description=COALESCE(p_description,description),
        "factsheetUrl"=COALESCE(p_factsheet_url,"factsheetUrl"),
        "prospectusUrl"=COALESCE(p_prospectus_url,"prospectusUrl"),
        quantity=COALESCE(p_quantity,quantity),
        is_active=COALESCE(p_is_active,is_active),
        is_coming_soon=COALESCE(p_is_coming_soon,is_coming_soon),
        platform_fee_discount=COALESCE(p_discount_percentage,platform_fee_discount),
        discount_updated_at=COALESCE(p_discount_updated_at,discount_updated_at),
        discount_updated_by=CASE WHEN p_discount_percentage IS NOT NULL OR p_discount_updated_at IS NOT NULL THEN p_user_id ELSE discount_updated_by END,
        updated_at=clock_timestamp()
    WHERE id=v_old.id;
    
    IF v_schedule THEN
        DELETE FROM "trade"."sukuk_investment_credit"
        WHERE call_event_id IN (
            SELECT id FROM "trade"."sukuk_call_event" WHERE inventory_id=p_id AND status::text='PENDING'
        );
        DELETE FROM "trade"."sukuk_call_event"
        WHERE inventory_id=p_id AND status::text='PENDING';
    END IF;
    
    OPEN p_cursor FOR
    SELECT i.* FROM "trade"."sukuk_inventory" i WHERE i.id = v_old.id;
    RETURN;
END $$;


-- Function: toggleInventoryStatus
-- Prisma await: await prisma.sukuk_inventory.findFirst(...)
-- Prisma await: await prisma.sukuk_inventory.update(...)
-- Purpose: Toggle inventory active status and return the updated inventory row.
CREATE OR REPLACE PROCEDURE "trade"."sp_toggle_inventory_status"(
    p_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "trade"."sukuk_inventory" SET is_active = NOT is_active, updated_at = clock_timestamp()
    WHERE inventory_id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Inventory not found'; END IF;
    OPEN p_cursor FOR SELECT i.* FROM "trade"."sukuk_inventory" i WHERE i.inventory_id = p_id;
END $$;

-- Function: deleteInventory
-- Prisma await: await prisma.sukuk_inventory.findFirst(...)
-- Prisma await: await prisma.sukuk_inventory.delete(...)
-- Purpose: Delete an inventory row and return the deleted inventory id.
CREATE OR REPLACE PROCEDURE "trade"."sp_delete_inventory"(
    p_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE v_deleted_id varchar;
BEGIN
    DELETE FROM "trade"."sukuk_inventory" WHERE inventory_id = p_id RETURNING inventory_id INTO v_deleted_id;
    IF v_deleted_id IS NULL THEN RAISE EXCEPTION 'Inventory not found'; END IF;
    OPEN p_cursor FOR SELECT v_deleted_id AS inventory_id;
END $$;

-- Function: searchInventory
-- Prisma await: await prisma.sukuk_inventory.findMany(...)
-- Purpose: Search active Sukuk inventory by name, issuer or description.
CREATE OR REPLACE PROCEDURE "trade"."sp_search_inventory"(
    p_query varchar,
    p_sector varchar DEFAULT NULL,
    p_currency varchar DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT i.* FROM "trade"."sukuk_inventory" i
WHERE i.is_active = true
  AND (i.name ILIKE '%'||p_query||'%' OR i.issuer ILIKE '%'||p_query||'%' OR COALESCE(i.description,'') ILIKE '%'||p_query||'%')
  AND (p_sector IS NULL OR i.sector = p_sector)
  AND (p_currency IS NULL OR i.currency = p_currency)
ORDER BY i.created_at DESC;
END $$;

-- Function: uploadInventoryDocuments
-- Prisma await: await prisma.sukuk_inventory.findFirst(...)
-- Prisma await: await prisma.sukuk_inventory.update(...)
-- Purpose: Update prospectus/factsheet URLs and return the updated inventory row.
CREATE OR REPLACE PROCEDURE "trade"."sp_upload_inventory_documents"(
    p_id varchar,
    p_prospectus_url varchar DEFAULT NULL,
    p_factsheet_url varchar DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "trade"."sukuk_inventory"
    SET "prospectusUrl" = COALESCE(p_prospectus_url,"prospectusUrl"),
        "factsheetUrl" = COALESCE(p_factsheet_url,"factsheetUrl"),
        updated_at = clock_timestamp()
    WHERE inventory_id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Inventory not found'; END IF;
    OPEN p_cursor FOR SELECT i.* FROM "trade"."sukuk_inventory" i WHERE i.inventory_id = p_id;
END $$;

-- Function: getQuote
-- Prisma await: await prisma.sukuk_inventory.findFirst(...)
-- Purpose: Fetch active inventory data required for quote calculation.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_inventory_for_quote"(
    p_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT i.* FROM "trade"."sukuk_inventory" i WHERE i.inventory_id = p_id AND i.is_active = true LIMIT 1;
END $$;

-- Function: getPriceHistory
-- Prisma await: await prisma.sukuk_inventory.findFirst(...)
-- Purpose: Fetch active inventory data required for price-history flow.
CREATE OR REPLACE PROCEDURE "trade"."sp_get_inventory_for_price_history"(
    p_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT i.* FROM "trade"."sukuk_inventory" i WHERE i.inventory_id = p_id AND i.is_active = true LIMIT 1;
END $$;

-- Function: getDepositAccounts
-- Prisma await: await prisma.companyBankAccount.findMany(...)
-- Purpose: Fetch active company bank accounts for deposits.
CREATE OR REPLACE PROCEDURE "payments"."sp_get_deposit_accounts"(
    p_currency varchar DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT id, bank_name, account_type, account_name, account_number, address, swift_code, iban, currency
FROM "payments"."company_bank_account"
WHERE is_active = true AND (p_currency IS NULL OR currency = upper(p_currency))
ORDER BY currency, created_at DESC;
END $$;

-- Function: createBankAccount
-- Prisma await: await prisma.companyBankAccount.create(...)
-- Purpose: Create a company bank account and return the created row.
CREATE OR REPLACE PROCEDURE "payments"."sp_create_bank_account"(
    p_bank_name varchar,
    p_account_type varchar,
    p_account_name varchar,
    p_account_number varchar,
    p_address text,
    p_swift_code varchar,
    p_iban varchar,
    p_currency varchar,
    p_is_active boolean DEFAULT true,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE v_id varchar(191) := 'cba_'||md5(random()::text||clock_timestamp()::text);
BEGIN
    IF p_bank_name IS NULL OR p_account_name IS NULL OR p_account_number IS NULL OR p_currency IS NULL THEN
        RAISE EXCEPTION 'bank_name, account_name, account_number, and currency are required';
    END IF;
    INSERT INTO "payments"."company_bank_account"(id,bank_name,account_type,account_name,account_number,address,swift_code,iban,currency,is_active,created_at,updated_at)
    VALUES(v_id,p_bank_name,p_account_type,p_account_name,p_account_number,p_address,p_swift_code,p_iban,upper(p_currency),COALESCE(p_is_active,true),clock_timestamp(),clock_timestamp());
    OPEN p_cursor FOR SELECT a.* FROM "payments"."company_bank_account" a WHERE a.id = v_id;
END $$;

-- Function: getAllBankAccounts
-- Prisma await: await prisma.companyBankAccount.findMany(...)
-- Purpose: Fetch all company bank accounts.
CREATE OR REPLACE PROCEDURE "payments"."sp_get_all_bank_accounts"(
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT a.* FROM "payments"."company_bank_account" a ORDER BY a.currency, a.created_at DESC;
END $$;

-- Function: updateBankAccount
-- Prisma await: await prisma.companyBankAccount.update(...)
-- Purpose: Update a company bank account and return the updated row.
CREATE OR REPLACE PROCEDURE "payments"."sp_update_bank_account"(
    p_id varchar,
    p_bank_name varchar DEFAULT NULL,
    p_account_type varchar DEFAULT NULL,
    p_account_name varchar DEFAULT NULL,
    p_account_number varchar DEFAULT NULL,
    p_address text DEFAULT NULL,
    p_swift_code varchar DEFAULT NULL,
    p_iban varchar DEFAULT NULL,
    p_currency varchar DEFAULT NULL,
    p_is_active boolean DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "payments"."company_bank_account" SET bank_name=COALESCE(p_bank_name,bank_name),
        account_type=COALESCE(p_account_type,account_type), account_name=COALESCE(p_account_name,account_name),
        account_number=COALESCE(p_account_number,account_number), address=COALESCE(p_address,address),
        swift_code=COALESCE(p_swift_code,swift_code), iban=COALESCE(p_iban,iban),
        currency=COALESCE(upper(p_currency),currency), is_active=COALESCE(p_is_active,is_active),
        updated_at=clock_timestamp()
    WHERE id=p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Bank account not found'; END IF;
    OPEN p_cursor FOR SELECT a.* FROM "payments"."company_bank_account" a WHERE a.id=p_id;
END $$;

-- Function: deleteBankAccount
-- Prisma await: await prisma.companyBankAccount.delete(...)
-- Purpose: Delete a company bank account and return the deleted id.
CREATE OR REPLACE PROCEDURE "payments"."sp_delete_bank_account"(
    p_id varchar,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE v_deleted_id varchar;
BEGIN
    DELETE FROM "payments"."company_bank_account" WHERE id=p_id RETURNING id INTO v_deleted_id;
    IF v_deleted_id IS NULL THEN RAISE EXCEPTION 'Bank account not found'; END IF;
    OPEN p_cursor FOR SELECT v_deleted_id AS id;
END $$;
COMMIT;
