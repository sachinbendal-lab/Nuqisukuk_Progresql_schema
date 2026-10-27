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
