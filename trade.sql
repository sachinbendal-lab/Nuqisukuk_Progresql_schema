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
