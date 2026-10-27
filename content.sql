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
