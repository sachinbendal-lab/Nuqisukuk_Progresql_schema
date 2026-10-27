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
