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
