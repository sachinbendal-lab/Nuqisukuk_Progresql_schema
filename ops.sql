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
