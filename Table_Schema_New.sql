
-- ============================================================================
-- 1. DROP EXTANT INTERFERENCE (IF APPLICABLE)
-- ============================================================================
-- DROP SCHEMA IF EXISTS public CASCADE;
-- CREATE SCHEMA public;
-- Ensure schemas exist before creating types and tables.
CREATE SCHEMA IF NOT EXISTS "catalog";
CREATE SCHEMA IF NOT EXISTS "content";
CREATE SCHEMA IF NOT EXISTS "integration";
CREATE SCHEMA IF NOT EXISTS "kyc";
CREATE SCHEMA IF NOT EXISTS "ops";
CREATE SCHEMA IF NOT EXISTS "payments";
CREATE SCHEMA IF NOT EXISTS "public";
CREATE SCHEMA IF NOT EXISTS "support";
CREATE SCHEMA IF NOT EXISTS "trade";
CREATE SCHEMA IF NOT EXISTS "user";


-- ============================================================================
-- 2. CUSTOM ENUM TYPE INITIALIZATIONS
-- ============================================================================
CREATE TYPE admin_user_gender AS ENUM ('MALE', 'FEMALE', 'OTHER');
CREATE TYPE admin_user_role AS ENUM ('USER', 'READ_ONLY', 'ADMIN', 'SUPER_ADMIN');
CREATE TYPE bank_account_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED', 'ON_HOLD');
CREATE TYPE csv_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED');
CREATE TYPE audit_change_type AS ENUM ('EXCEL_UPLOAD_CREATE', 'EXCEL_UPLOAD_UPDATE');
CREATE TYPE risk_level_type AS ENUM ('CONSERVATIVE', 'BALANCED', 'GROWTH', 'AGGRESSIVE');
CREATE TYPE splash_screen_type AS ENUM ('mp4', 'lottie');
CREATE TYPE sukuk_event_status AS ENUM ('PENDING', 'PROCESSING', 'COMPLETED', 'SKIPPED');
CREATE TYPE sukuk_event_type AS ENUM ('COUPON', 'CALL', 'MATURITY');
CREATE TYPE profit_frequency_type AS ENUM ('Monthly', 'Quarterly', 'SemiAnnually', 'Annually');
CREATE TYPE sukuk_convention_type AS ENUM ('Actual360', 'Thirty360');
CREATE TYPE ticket_priority AS ENUM ('LOW', 'MEDIUM', 'HIGH', 'URGENT');
CREATE TYPE transaction_type_enum AS ENUM ('BUY', 'SELL', 'CREDIT');
CREATE TYPE status_enum AS ENUM ('PENDING', 'COMPLETED', 'FAILED', 'CANCELLED');
CREATE TYPE kyc_status_enum AS ENUM ('PENDING', 'ACCEPTED', 'INPROGRESS', 'DECLINED', 'VERIFIED', 'EXPIRED');
CREATE TYPE wallet_trans_type AS ENUM ('DEPOSIT', 'WITHDRAWAL', 'CREDIT', 'DEBIT', 'FEE');
CREATE TYPE withdrawal_status AS ENUM ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED', 'CANCELLED');
CREATE TYPE deposit_status_enum AS ENUM ('PENDING', 'APPROVED', 'REJECTED');
CREATE TYPE profit_frequency_enum AS ENUM ('Monthly', 'Quarterly', 'SemiAnnually', 'Annually');
CREATE TYPE convention_enum AS ENUM ('Actual360', 'Thirty360');
CREATE TYPE profit_type_enum AS ENUM ('Fixed', 'Floating');
CREATE TYPE gender_enum AS ENUM ('MALE', 'FEMALE', 'OTHER');
CREATE TYPE role_enum AS ENUM ('USER', 'READ_ONLY', 'ADMIN', 'SUPER_ADMIN');
CREATE TYPE walletstatus AS ENUM ('ACTIVE', 'SUSPENDED', 'CLOSED');
 

-- ============================================================================
-- 3. CORE ISOLATED USER & CONFIG REFERENCE ARCHITECTURE
-- ============================================================================

CREATE TABLE "ops"."_prisma_migrations" (
    "id" varchar(36) NOT NULL,
    "checksum" varchar(64) NOT NULL,
    "finished_at" timestamp(3) DEFAULT NULL,
    "migration_name" varchar(255) NOT NULL,
    "logs" text DEFAULT NULL,
    "rolled_back_at" timestamp(3) DEFAULT NULL,
    "started_at" timestamp(3) NOT NULL,
    "applied_steps_count" integer NOT NULL,
    CONSTRAINT "pk_prisma_migrations" PRIMARY KEY ("id")
);

CREATE TABLE "ops"."admin_user" (
    "id" integer NOT NULL,
    "userId" varchar(191) NOT NULL,
    "email" varchar(191) NOT NULL,
    "phone_number" varchar(191) DEFAULT NULL,
    "phone_prefix" varchar(191) DEFAULT NULL,
    "password" varchar(191) NOT NULL,
    "first_name" varchar(191) NOT NULL,
    "last_name" varchar(191) NOT NULL,
    "gender" admin_user_gender DEFAULT NULL,
    "role" admin_user_role NOT NULL,
    "token" text DEFAULT NULL,
    "token_expiry_time" varchar(191) DEFAULT NULL,
    "client_secret" text DEFAULT NULL,
    "secret_expires" timestamp(3) DEFAULT NULL,
    "customer_number" varchar(191) DEFAULT NULL,
    "is_deleted" boolean NOT NULL DEFAULT FALSE,
    "is_active" boolean NOT NULL DEFAULT TRUE,
    "is_email_verified" boolean NOT NULL DEFAULT FALSE,
    "is_phone_verified" boolean NOT NULL DEFAULT FALSE,
    "last_login_region" varchar(191) DEFAULT NULL,
    "created_by" integer DEFAULT NULL,
    "created_at" timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp(3) NOT NULL,
    "token_version" integer NOT NULL DEFAULT 1,
    CONSTRAINT "pk_admin_user" PRIMARY KEY ("id"),
    CONSTRAINT "uq_admin_user_userid" UNIQUE ("userId"),
    CONSTRAINT "uq_admin_user_email" UNIQUE ("email")
);

CREATE TABLE IF NOT EXISTS "user"."user" (
    "id" SERIAL,
    "userId" VARCHAR(191) NOT NULL, 
    "google_id" VARCHAR(191) DEFAULT NULL, 
    "email" VARCHAR(191) DEFAULT NULL, 
    "username" VARCHAR(191) DEFAULT NULL, 
    "first_name" VARCHAR(191) DEFAULT NULL, 
    "last_name" VARCHAR(191) DEFAULT NULL, 
    "gender" gender_enum DEFAULT NULL, 
    "phone_number" VARCHAR(191) DEFAULT NULL, 
    "phone_prefix" VARCHAR(191) DEFAULT NULL, 
    "password" VARCHAR(191) DEFAULT NULL, 
    "apple_id" VARCHAR(191) DEFAULT NULL, 
    "last_login_region" VARCHAR(191) DEFAULT NULL, 
    "profileUrl" VARCHAR(191) DEFAULT NULL, 
    "address" VARCHAR(191) DEFAULT NULL, 
    "kyc_status" kyc_status_enum DEFAULT NULL, 
    "bankkyc_status" VARCHAR(191) DEFAULT NULL, 
    "currency_pref" VARCHAR(191) DEFAULT NULL, 
    "notification_token" VARCHAR(191) DEFAULT NULL, 
    "date_of_birth" TIMESTAMP(3) DEFAULT NULL, 
    "is_tnc_checked" BOOLEAN DEFAULT FALSE, 
    "referral" VARCHAR(191) DEFAULT NULL, 
    "customer_number" VARCHAR(191) DEFAULT NULL, 
    "token" TEXT DEFAULT NULL, 
    "token_expiry_time" VARCHAR(191) DEFAULT NULL, 
    "client_secret" VARCHAR(191) DEFAULT NULL, 
    "secret_expires" TIMESTAMP(3) DEFAULT NULL, 
    "platform" VARCHAR(191) DEFAULT NULL, 
    "role" role_enum NOT NULL DEFAULT 'USER', 
    "is_phone_verified" BOOLEAN NOT NULL DEFAULT FALSE, 
    "is_email_verified" BOOLEAN NOT NULL DEFAULT FALSE, 
    "is_kyc_verified" BOOLEAN NOT NULL DEFAULT FALSE, 
    "is_bank_kyc_verified" BOOLEAN NOT NULL DEFAULT FALSE, 
    "is_risk_verified" BOOLEAN NOT NULL DEFAULT FALSE, 
    "is_deleted" BOOLEAN NOT NULL DEFAULT FALSE, 
    "is_active" BOOLEAN NOT NULL DEFAULT TRUE, 
    "created_by" VARCHAR(191) DEFAULT NULL, 
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP, 
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP, 
    "mpin_otp_expires" TIMESTAMP(3) DEFAULT NULL, 
    "mpin_otp_hash" TEXT DEFAULT NULL, 
    "mpin_reset_token" VARCHAR(191) DEFAULT NULL, 
    "mpin_reset_token_expires" TIMESTAMP(3) DEFAULT NULL, 
    "mpinhash" VARCHAR(191) DEFAULT NULL, 
    "token_version" INT NOT NULL DEFAULT 0,

    CONSTRAINT pk_user PRIMARY KEY ("id"),
    CONSTRAINT uq_user_id UNIQUE ("userId"),
    CONSTRAINT uq_user_email UNIQUE ("email"),
    CONSTRAINT uq_user_customer_number UNIQUE ("customer_number")
);


CREATE TABLE "catalog"."app_config" (
    "id" integer NOT NULL,
    "key" varchar(191) NOT NULL,
    "value" varchar(191) NOT NULL,
    "min_app_version" varchar(191) DEFAULT NULL,
    "platform" varchar(191) DEFAULT NULL,
    "updated_at" timestamp(3) NOT NULL,
    "updated_by" varchar(191) DEFAULT NULL,
    CONSTRAINT "pk_app_config" PRIMARY KEY ("id"),
    CONSTRAINT "uq_app_config_key" UNIQUE ("key")
);

CREATE TABLE "catalog"."app_config_history" (
    "id" integer NOT NULL,
    "config_key" varchar(191) NOT NULL,
    "old_value" varchar(191) DEFAULT NULL,
    "new_value" varchar(191) NOT NULL,
    "changed_by" varchar(191) NOT NULL,
    "metadata" jsonb DEFAULT NULL,
    "changed_at" timestamp(3) NOT NULL,
    CONSTRAINT "pk_app_config_history" PRIMARY KEY ("id")
);

CREATE TABLE "ops"."audit_logs" (
    "id" integer NOT NULL,
    "module" varchar(191) NOT NULL,
    "actionType" varchar(191) NOT NULL,
    "entityType" varchar(191) NOT NULL,
    "entityId" varchar(191) NOT NULL,
    "statusBefore" varchar(191) DEFAULT NULL,
    "statusAfter" varchar(191) DEFAULT NULL,
    "actionReason" text DEFAULT NULL,
    "adminEmail" varchar(191) NOT NULL,
    "adminName" varchar(191) DEFAULT NULL,
    "ipAddress" varchar(191) DEFAULT NULL,
    "browser" text DEFAULT NULL,
    "success" boolean NOT NULL,
    "metadata" jsonb DEFAULT NULL,
    "createdAt" timestamp(3) NOT NULL,
    CONSTRAINT "pk_audit_logs" PRIMARY KEY ("id")
);

CREATE TABLE "ops"."permissions" (
    "id" varchar(191) NOT NULL,
    "admin_user_id" integer NOT NULL,
    "module_name" varchar(191) NOT NULL,
    "can_create" boolean NOT NULL,
    "can_read" boolean NOT NULL,
    "can_update" boolean NOT NULL,
    "can_delete" boolean NOT NULL,
    "created_at" timestamp(3) NOT NULL,
    "updated_at" timestamp(3) NOT NULL,
    "can_activate" boolean NOT NULL,
    "can_deactivate" boolean NOT NULL,
    CONSTRAINT "pk_permissions" PRIMARY KEY ("id"),
    CONSTRAINT "fk_permissions_admin" FOREIGN KEY ("admin_user_id") REFERENCES "ops"."admin_user"("id") ON DELETE CASCADE
);

CREATE TABLE "content"."contact" (
    "id" integer NOT NULL,
    "contact_id" varchar(191) NOT NULL,
    "name" varchar(191) NOT NULL,
    "email" varchar(191) NOT NULL,
    "phone" varchar(191) DEFAULT NULL,
    "investment_interest" text DEFAULT NULL,
    "message" text NOT NULL,
    "is_resolved" boolean NOT NULL DEFAULT FALSE,
    "created_at" timestamp(3) NOT NULL,
    "updated_at" timestamp(3) NOT NULL,
    CONSTRAINT "pk_contact" PRIMARY KEY ("id")
);

CREATE TABLE "trade"."public_holiday" (
    "id" integer NOT NULL,
    "date" date NOT NULL,
    "name" varchar(191) NOT NULL,
    "country" varchar(191) NOT NULL,
    "created_at" timestamp(3) NOT NULL,
    CONSTRAINT "pk_public_holiday" PRIMARY KEY ("id")
);

CREATE TABLE "catalog"."reason_templates" (
    "id" integer NOT NULL,
    "ref_id" varchar(191) NOT NULL,
    "subject" varchar(191) NOT NULL,
    "reason" text NOT NULL,
    "html_content" text DEFAULT NULL,
    "context_table" varchar(191) NOT NULL,
    "reason_type" varchar(191) NOT NULL,
    "status" varchar(191) NOT NULL,
    "created_at" timestamp(3) NOT NULL,
    "updated_at" timestamp(3) NOT NULL,
    CONSTRAINT "pk_reason_templates" PRIMARY KEY ("id")
);

CREATE TABLE "user"."refresh_tokens" (
    "id" varchar(191) NOT NULL,
    "token_hash" varchar(191) NOT NULL,
    "user_id" varchar(191) NOT NULL,
    "user_type" varchar(191) NOT NULL,
    "family_id" varchar(191) NOT NULL,
    "token_version" integer NOT NULL,
    "device_info" jsonb DEFAULT NULL,
    "expires_at" timestamp(3) NOT NULL,
    "is_used" boolean NOT NULL DEFAULT FALSE,
    "revoked_at" timestamp(3) DEFAULT NULL,
    "revoked_reason" varchar(191) DEFAULT NULL,
    "created_at" timestamp(3) NOT NULL,
    CONSTRAINT "pk_refresh_tokens" PRIMARY KEY ("id")
);

CREATE TABLE "user"."registration_staging" (
    "id" varchar(191) NOT NULL,
    "email" varchar(191) DEFAULT NULL,
    "phone_number" varchar(191) DEFAULT NULL,
    "phone_prefix" varchar(191) DEFAULT NULL,
    "otp_hash" text DEFAULT NULL,
    "metadata" jsonb DEFAULT NULL,
    "expires_at" timestamp(3) NOT NULL,
    "created_at" timestamp(3) NOT NULL,
    CONSTRAINT "pk_registration_staging" PRIMARY KEY ("id")
);

CREATE TABLE "content"."splash_screen" (
    "id" integer NOT NULL,
    "name" varchar(191) DEFAULT NULL,
    "screen_type" splash_screen_type NOT NULL,
    "videoPath" text NOT NULL,
    "mimetype" varchar(191) DEFAULT NULL,
    "status" boolean NOT NULL,
    "created_at" timestamp(3) NOT NULL,
    "updated_at" timestamp(3) NOT NULL,
    CONSTRAINT "pk_splash_screen" PRIMARY KEY ("id")
);

-- ============================================================================
-- 4. TICKETING SYSTEM ENGINE TABLES
-- ============================================================================

CREATE TABLE "support"."ticketcategoryconfig" (
    "id" varchar(191) NOT NULL,
    "name" varchar(191) NOT NULL,
    "description" text DEFAULT NULL,
    "icon" varchar(191) DEFAULT NULL,
	"attachmentRequired" boolean NOT NULL,
	"sortOrder" integer NOT NULL,
	"isActive" boolean NOT NULL,
	"createdAt" timestamp(3) NOT NULL,
	"updatedAt" timestamp(3) NOT NULL,
	CONSTRAINT "pk_ticketcategoryconfig" PRIMARY KEY ("id"));
	
CREATE TABLE "support"."ticketsubcategory" (
"id" varchar(191) NOT NULL,
"categoryId" varchar(191) NOT NULL,
"name" varchar(191) NOT NULL,
"description" text DEFAULT NULL,
"attachmentRequired" boolean DEFAULT NULL,
"sortOrder" integer NOT NULL,
"isActive" boolean NOT NULL,
"createdAt" timestamp(3) NOT NULL,
"updatedAt" timestamp(3) NOT NULL,
CONSTRAINT "pk_ticketsubcategory" PRIMARY KEY ("id"),
CONSTRAINT "fk_ticketsubcategory_category" FOREIGN KEY ("categoryId") REFERENCES "support"."ticketcategoryconfig"("id") ON DELETE CASCADE
);
CREATE TABLE "support"."ticket" (
"id" varchar(191) NOT NULL,
"ticketNumber" varchar(191) NOT NULL,
"customer_number" varchar(191) DEFAULT NULL,
"categoryId" varchar(191) DEFAULT NULL,
"subcategoryId" varchar(191) DEFAULT NULL,
"subject" varchar(191) NOT NULL,
"description" text NOT NULL,
"priority" ticket_priority NOT NULL,
"status" varchar(191) NOT NULL,
"assignedTo" varchar(191) DEFAULT NULL,
"resolution" text DEFAULT NULL,
"escalationLevel" integer NOT NULL,
"attachments" jsonb DEFAULT NULL,
"metadata" jsonb DEFAULT NULL,
"firstResponseAt" timestamp(3) DEFAULT NULL,
"resolvedAt" timestamp(3) DEFAULT NULL,
"closedAt" timestamp(3) DEFAULT NULL,
"rating" integer DEFAULT NULL,
"ratingFeedback" text DEFAULT NULL,
"ratedAt" timestamp(3) DEFAULT NULL,
"createdAt" timestamp(3) NOT NULL,
"updatedAt" timestamp(3) NOT NULL,
CONSTRAINT "pk_ticket" PRIMARY KEY ("id"),
CONSTRAINT "uq_ticket_number" UNIQUE ("ticketNumber"),
CONSTRAINT "fk_ticket_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE SET NULL,
CONSTRAINT "fk_ticket_category" FOREIGN KEY ("categoryId") REFERENCES "support"."ticketcategoryconfig"("id") ON DELETE SET NULL,
CONSTRAINT "fk_ticket_subcategory" FOREIGN KEY ("subcategoryId") REFERENCES "support"."ticketsubcategory"("id") ON DELETE SET NULL
);
CREATE TABLE "support"."ticketassignee" (
"id" varchar(191) NOT NULL,
"name" varchar(191) NOT NULL,
"email" varchar(191) DEFAULT NULL,
"role" varchar(191) DEFAULT NULL,
"department" varchar(191) DEFAULT NULL,
"sortOrder" integer NOT NULL,
"isActive" boolean NOT NULL,
"createdAt" timestamp(3) NOT NULL,
"updatedAt" timestamp(3) NOT NULL,
CONSTRAINT "pk_ticketassignee" PRIMARY KEY ("id")
);
CREATE TABLE "support"."ticketcomment" (
"id" varchar(191) NOT NULL,
"ticketId" varchar(191) NOT NULL,
"customer_number" varchar(191) DEFAULT NULL,
"message" text NOT NULL,
"commentBy" varchar(191) NOT NULL,
"commentType" varchar(191) NOT NULL,
"isInternal" boolean NOT NULL,
"attachments" jsonb DEFAULT NULL,
"createdAt" timestamp(3) NOT NULL,
"updatedAt" timestamp(3) NOT NULL,
CONSTRAINT "pk_ticketcomment" PRIMARY KEY ("id"),
CONSTRAINT "fk_ticketcomment_ticket" FOREIGN KEY ("ticketId") REFERENCES "support"."ticket"("id") ON DELETE CASCADE,
CONSTRAINT "fk_ticketcomment_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE SET NULL
);
CREATE TABLE "support"."ticketpriorityconfig" (
"id" varchar(191) NOT NULL,
"name" varchar(191) NOT NULL,
"label" varchar(191) DEFAULT NULL,
"description" text DEFAULT NULL,
"color" varchar(191) DEFAULT NULL,
"bgColor" varchar(191) DEFAULT NULL,
"sortOrder" integer NOT NULL,
"isDefault" boolean NOT NULL,
"isActive" boolean NOT NULL,
"createdAt" timestamp(3) NOT NULL,
"updatedAt" timestamp(3) NOT NULL,
CONSTRAINT "pk_ticketpriorityconfig" PRIMARY KEY ("id")
);
CREATE TABLE "support"."ticketstatusconfig" (
"id" varchar(191) NOT NULL,
"name" varchar(191) NOT NULL,
"label" varchar(191) NOT NULL,
"description" text DEFAULT NULL,
"color" varchar(191) NOT NULL,
"bgColor" varchar(191) NOT NULL,
"icon" varchar(191) DEFAULT NULL,
"statusType" varchar(191) NOT NULL,
"sortOrder" integer NOT NULL,
"isDefault" boolean NOT NULL,
"isFinal" boolean NOT NULL,
"isActive" boolean NOT NULL,
"createdAt" timestamp(3) NOT NULL,
"updatedAt" timestamp(3) NOT NULL,
CONSTRAINT "pk_ticketstatusconfig" PRIMARY KEY ("id")
);
-- ============================================================================
-- 5. SUKUK & FINANCIAL OPERATIONS DATA INFRASTRUCTURE
-- ============================================================================
CREATE TABLE IF NOT EXISTS "trade"."sukuk_inventory" (
    "id" INT NOT NULL, 
    "inventory_id" VARCHAR(191) NOT NULL, 
    "name" VARCHAR(191) NOT NULL, 
    "issuer" VARCHAR(191) NOT NULL, 
    "issuerLogo" VARCHAR(191) DEFAULT NULL, 
    "country" VARCHAR(191) DEFAULT NULL, 
    "sector" TEXT DEFAULT NULL, 
    "type" TEXT DEFAULT NULL, 
    "ytm" DOUBLE PRECISION NOT NULL, 
    "ytc" DOUBLE PRECISION DEFAULT NULL, 
    "profitRate" DOUBLE PRECISION NOT NULL, 
    "profitFrequency" profit_frequency_enum DEFAULT NULL, 
    "maturityDate" TIMESTAMP(3) DEFAULT NULL, 
    "issueDate" TIMESTAMP(3) DEFAULT NULL, 
    "bidPrice" DOUBLE PRECISION DEFAULT NULL, 
    "askPrice" DOUBLE PRECISION DEFAULT NULL, 
    "minFractionalInvestment" DOUBLE PRECISION DEFAULT NULL, 
    "fractionalQuantity" DOUBLE PRECISION DEFAULT NULL, 
    "fullSizeTicket" DOUBLE PRECISION DEFAULT NULL, 
    "accruedInterest" DOUBLE PRECISION DEFAULT NULL, 
    "convention" convention_enum DEFAULT NULL, 
    "faceValue" DOUBLE PRECISION DEFAULT NULL, 
    "isin" VARCHAR(191) DEFAULT NULL, 
    "currency" VARCHAR(191) NOT NULL, 
    "marketCap" DOUBLE PRECISION DEFAULT NULL, 
    "priceHistory" JSON DEFAULT NULL, 
    "description" TEXT DEFAULT NULL, 
    "factsheetUrl" VARCHAR(191) DEFAULT NULL, 
    "prospectusUrl" VARCHAR(191) DEFAULT NULL, 
    "fitchRating" VARCHAR(191) DEFAULT NULL, 
    "previousClose" DOUBLE PRECISION DEFAULT NULL, 
    "profitType" profit_type_enum DEFAULT NULL, 
    "lastTradedPrice" DOUBLE PRECISION DEFAULT NULL, 
    "callDate" TIMESTAMP(3) DEFAULT NULL, 
    "lastTradedQuantity" INT DEFAULT NULL, 
    "amountIssued" DOUBLE PRECISION DEFAULT NULL, 
    "ranking" VARCHAR(191) DEFAULT NULL, 
    "ytdChange" DOUBLE PRECISION DEFAULT NULL, 
    "minIncrement" DOUBLE PRECISION DEFAULT NULL, 
    "corporateAction" VARCHAR(191) DEFAULT NULL, 
    "quantity" INT NOT NULL DEFAULT 0, 
    "is_active" BOOLEAN NOT NULL DEFAULT TRUE, 
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP, 
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP, 
    "is_coming_soon" BOOLEAN NOT NULL DEFAULT FALSE, 
    "discount_updated_at" TIMESTAMP(3) DEFAULT NULL, 
    "discount_updated_by" VARCHAR(191) DEFAULT NULL, 
    "platform_fee_discount" DECIMAL(5,2) NOT NULL DEFAULT 0.00, 
    "benchmark_rate" DOUBLE PRECISION DEFAULT NULL, 
    "reset_date" DATE DEFAULT NULL, 
    "spread" DOUBLE PRECISION DEFAULT NULL, 
    "ibkr_conid" VARCHAR(191) DEFAULT NULL, 
    "callSchedule" JSON DEFAULT NULL,

    CONSTRAINT pk_sukuk_inventory PRIMARY KEY ("id"),
    CONSTRAINT uq_sukuk_inventory_id UNIQUE ("inventory_id"),
    CONSTRAINT uq_sukuk_isin UNIQUE ("isin"),
    CONSTRAINT chk_positive_quantity CHECK ("quantity" >= 0)
);

CREATE TABLE "trade"."sukuk_call_event" (
"id" integer NOT NULL,
"event_id" varchar(191) NOT NULL,
"inventory_id" varchar(191) NOT NULL,
"call_date" date NOT NULL,
"ops_alerted_at" timestamp(3) DEFAULT NULL,
"status" sukuk_event_status NOT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
"event_type" sukuk_event_type NOT NULL,
CONSTRAINT "pk_sukuk_call_event" PRIMARY KEY ("id"),
CONSTRAINT "uq_sukuk_call_event_id" UNIQUE ("event_id"),
CONSTRAINT "fk_sukuk_call_event_inventory" FOREIGN KEY ("inventory_id") REFERENCES "trade"."sukuk_inventory"("inventory_id") ON DELETE CASCADE
);
CREATE TABLE "trade"."sukuk_investment" (
"id" integer NOT NULL,
"investment_id" varchar(191) NOT NULL,
"inventory_id" varchar(191) NOT NULL,
"customer_number" varchar(191) NOT NULL,
"principal" decimal(15,2) NOT NULL,
"is_final_maturity" boolean NOT NULL,
"is_active" boolean NOT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_sukuk_investment" PRIMARY KEY ("id"),
CONSTRAINT "uq_sukuk_investment_id" UNIQUE ("investment_id"),
CONSTRAINT "fk_sukuk_investment_inventory" FOREIGN KEY ("inventory_id") REFERENCES "trade"."sukuk_inventory"("inventory_id") ON DELETE RESTRICT,
CONSTRAINT "fk_sukuk_investment_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE RESTRICT
);
CREATE TABLE "trade"."sukuk_investment_credit" (
"id" integer NOT NULL,
"credit_id" varchar(191) NOT NULL,
"call_event_id" integer NOT NULL,
"investment_id" integer NOT NULL,
"profit_amount" decimal(15,2) NOT NULL,
"principal_amount" decimal(15,2) NOT NULL,
"wallet_credited_at" timestamp(3) DEFAULT NULL,
"investor_notified_at" timestamp(3) DEFAULT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
"customer_number" varchar(191) NOT NULL,
CONSTRAINT "pk_sukuk_investment_credit" PRIMARY KEY ("id"),
CONSTRAINT "uq_sukuk_credit_id" UNIQUE ("credit_id"),
CONSTRAINT "fk_sukuk_credit_event" FOREIGN KEY ("call_event_id") REFERENCES "trade"."sukuk_call_event"("id") ON DELETE RESTRICT,
CONSTRAINT "fk_sukuk_credit_investment" FOREIGN KEY ("investment_id") REFERENCES "trade"."sukuk_investment"("id") ON DELETE RESTRICT,
CONSTRAINT "fk_sukuk_credit_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE RESTRICT
);
CREATE TABLE "trade"."sukuk_price_history" (
"id" integer NOT NULL,
"inventory_id" varchar(191) NOT NULL,
"conid" varchar(191) NOT NULL,
"bar" varchar(191) NOT NULL,
"timestamp" timestamp(3) NOT NULL,
"open" double precision DEFAULT NULL,
"high" double precision DEFAULT NULL,
"low" double precision DEFAULT NULL,
"close" double precision DEFAULT NULL,
"volume" double precision DEFAULT NULL,
"created_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_sukuk_price_history" PRIMARY KEY ("id"),
CONSTRAINT "fk_sukuk_price_history_inventory" FOREIGN KEY ("inventory_id") REFERENCES "trade"."sukuk_inventory"("inventory_id") ON DELETE CASCADE
);
CREATE TABLE "trade"."inventory_audit_log" (
"id" integer NOT NULL,
"audit_id" varchar(191) NOT NULL,
"inventory_id" varchar(191) NOT NULL,
"change_type" audit_change_type NOT NULL,
"changed_by_id" varchar(191) DEFAULT NULL,
"changed_by_name" varchar(191) DEFAULT NULL,
"changed_at" timestamp(3) NOT NULL,
"data_before" jsonb DEFAULT NULL,
"data_after" jsonb DEFAULT NULL,
"change_reason" text DEFAULT NULL,
"batch_id" varchar(191) DEFAULT NULL,
"created_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_inventory_audit_log" PRIMARY KEY ("id"),
CONSTRAINT "fk_inventory_audit_inventory" FOREIGN KEY ("inventory_id") REFERENCES "trade"."sukuk_inventory"("inventory_id") ON DELETE CASCADE
);
CREATE TABLE "trade"."investment_snapshot" (
"id" integer NOT NULL,
"snapshot_id" varchar(191) NOT NULL,
"customer_number" varchar(191) NOT NULL,
"inventory_id" varchar(191) NOT NULL,
"sukuk_name" varchar(191) NOT NULL,
"issuer" varchar(191) DEFAULT NULL,
"isin" varchar(191) DEFAULT NULL,
"currency" varchar(191) NOT NULL,
"status" varchar(191) NOT NULL,
"bought_date" timestamp(3) DEFAULT NULL,
"bought_quantity" integer NOT NULL,
"total_invested" decimal(15,2) NOT NULL,
"total_returned" decimal(15,2) NOT NULL,
"maturity_date" timestamp(3) DEFAULT NULL,
"timeline" jsonb NOT NULL,
"matured_at" timestamp(3) NOT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_investment_snapshot" PRIMARY KEY ("id"),
CONSTRAINT "fk_investment_snapshot_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE CASCADE,
CONSTRAINT "fk_investment_snapshot_inventory" FOREIGN KEY ("inventory_id") REFERENCES "trade"."sukuk_inventory"("inventory_id") ON DELETE RESTRICT
);
-- ============================================================================
-- 6. CUSTOMER WALLET, LEDGER, LOGISTICS, & VERIFICATION
-- ============================================================================
CREATE TABLE "kyc"."bank_verification" (
"id" VARCHAR(191) NOT NULL,
"customer_number" varchar(191) NOT NULL,
"holder_name" varchar(191) NOT NULL,
"account_number" varchar(191) NOT NULL,
"bank_name" varchar(191) NOT NULL,
"branch_name" varchar(191) NOT NULL,
"ifsc_code" varchar(191) NOT NULL,
"iban" varchar(191) NOT NULL,
"document_type" varchar(191) NOT NULL,
"document_url" varchar(191) NOT NULL,
"account_status" bank_account_status NOT NULL,
"is_primary" boolean NOT NULL,
"is_active" boolean NOT NULL,
"createdAt" timestamp(3) NOT NULL,
"updatedAt" timestamp(3) NOT NULL,
"onhold_template_id" integer DEFAULT NULL,
"rejection_template_id" integer DEFAULT NULL,
CONSTRAINT "pk_bank_verification" PRIMARY KEY ("id"),
CONSTRAINT "fk_bank_verification_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE CASCADE
);
CREATE TABLE "payments"."company_bank_account" (
"id" varchar(191) NOT NULL,
"bank_name" varchar(191) NOT NULL,
"account_type" varchar(191) DEFAULT NULL,
"account_name" varchar(191) NOT NULL,
"account_number" varchar(191) NOT NULL,
"address" text DEFAULT NULL,
"swift_code" varchar(191) DEFAULT NULL,
"iban" varchar(191) DEFAULT NULL,
"currency" varchar(191) NOT NULL,
"is_active" boolean NOT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_company_bank_account" PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "payments"."deposit_csv" (
    "id" VARCHAR(191) NOT NULL, 
    "batch_id" VARCHAR(191) NOT NULL, 
    "customer_number" VARCHAR(191) DEFAULT NULL, 
    "period_from" VARCHAR(191) DEFAULT NULL, 
    "period_to" VARCHAR(191) DEFAULT NULL, 
    "account_number" VARCHAR(191) DEFAULT NULL, 
    "currency" VARCHAR(191) NOT NULL, 
    "portfolio" VARCHAR(191) DEFAULT NULL, 
    "portfolio_name" VARCHAR(191) DEFAULT NULL, 
    "opening_balance" DECIMAL(15,2) DEFAULT NULL, 
    "transaction_date" TIMESTAMP(3) DEFAULT NULL, 
    "value_date" TIMESTAMP(3) DEFAULT NULL, 
    "transaction_type" VARCHAR(191) DEFAULT NULL, 
    "description" TEXT DEFAULT NULL, 
    "amount_credited" DECIMAL(15,2) NOT NULL, 
    "closing_balance" DECIMAL(15,2) DEFAULT NULL, 
    "reference_no" VARCHAR(191) DEFAULT NULL, 
    "transaction_reference" TEXT DEFAULT NULL, 
    "status" deposit_status_enum NOT NULL DEFAULT 'PENDING', 
    "is_valid" BOOLEAN NOT NULL DEFAULT TRUE, 
    "is_duplicate" BOOLEAN NOT NULL DEFAULT FALSE, 
    "validation_error" TEXT DEFAULT NULL, 
    "processed_by" VARCHAR(191) DEFAULT NULL, 
    "processed_at" TIMESTAMP(3) DEFAULT NULL, 
    "rejection_reason" TEXT DEFAULT NULL, 
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP, 
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_deposit_csv PRIMARY KEY ("id"),
    CONSTRAINT fk_deposit_user FOREIGN KEY ("customer_number") 
    REFERENCES "user"."user" ("customer_number") ON DELETE SET NULL ON UPDATE CASCADE
);

CREATE TABLE "catalog"."global_discount_config" (
"id" integer NOT NULL,
"discount_percentage" decimal(5,2) NOT NULL,
"is_active" boolean NOT NULL,
"updated_by" varchar(191) DEFAULT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_global_discount_config" PRIMARY KEY ("id")
);
CREATE TABLE "support"."helpcategory" (
"id" varchar(191) NOT NULL,
"title" varchar(191) NOT NULL,
"description" text DEFAULT NULL,
"icon" varchar(191) DEFAULT NULL,
"sortOrder" integer NOT NULL,
"isActive" boolean NOT NULL,
"createdAt" timestamp(3) NOT NULL,
"updatedAt" timestamp(3) NOT NULL,
CONSTRAINT "pk_helpcategory" PRIMARY KEY ("id")
);
CREATE TABLE "support"."helpfaq" (
"id" varchar(191) NOT NULL,
"question" varchar(191) NOT NULL,
"answer" text NOT NULL,
"categoryId" varchar(191) NOT NULL,
"videoId" varchar(191) DEFAULT NULL,
"sortOrder" integer NOT NULL,
"isActive" boolean NOT NULL,
"createdAt" timestamp(3) NOT NULL,
"updatedAt" timestamp(3) NOT NULL,
CONSTRAINT "pk_helpfaq" PRIMARY KEY ("id"),
CONSTRAINT "fk_helpfaq_category" FOREIGN KEY ("categoryId") REFERENCES "support"."helpcategory"("id") ON DELETE CASCADE
);
CREATE TABLE "content"."helpvideo" (
"id" varchar(191) NOT NULL,
"title" varchar(191) NOT NULL,
"description" text DEFAULT NULL,
"url" varchar(191) NOT NULL,
"thumbnailUrl" varchar(191) DEFAULT NULL,
"categoryId" varchar(191) DEFAULT NULL,
"tags" jsonb DEFAULT NULL,
"duration" integer DEFAULT NULL,
"sortOrder" integer NOT NULL,
"isActive" boolean NOT NULL,
"viewCount" integer NOT NULL DEFAULT 0,
"createdAt" timestamp(3) NOT NULL,
"updatedAt" timestamp(3) NOT NULL,
CONSTRAINT "pk_helpvideo" PRIMARY KEY ("id"),
CONSTRAINT "fk_helpvideo_category" FOREIGN KEY ("categoryId") REFERENCES "support"."helpcategory"("id") ON DELETE SET NULL
);
CREATE TABLE "kyc"."kyc" (
"id" integer NOT NULL,
"kyc_id" varchar(191) NOT NULL,
"user_id" integer NOT NULL,
"customer_number" varchar(191) NOT NULL,
"full_name" varchar(191) DEFAULT NULL,
"date_of_birth" varchar(191) DEFAULT NULL,
"gender" varchar(191) DEFAULT NULL,
"address" text DEFAULT NULL,
"document_type" varchar(191) DEFAULT NULL,
"document_number" varchar(191) DEFAULT NULL,
"reference_id" varchar(191) DEFAULT NULL,
"status" varchar(191) DEFAULT NULL,
"decline_reason" text DEFAULT NULL,
"facia_response" jsonb DEFAULT NULL,
"verified_at" timestamp(3) DEFAULT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_kyc" PRIMARY KEY ("id"),
CONSTRAINT "fk_kyc_user" FOREIGN KEY ("user_id") REFERENCES "user"."user"("id") ON DELETE CASCADE,
CONSTRAINT "fk_kyc_customer" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE CASCADE
);
CREATE TABLE "trade"."portfolio" (
"id" integer NOT NULL,
"portfolio_id" varchar(191) NOT NULL,
"customer_number" varchar(191) NOT NULL,
"inventory_id" varchar(191) NOT NULL,
"quantity" integer NOT NULL,
"average_buy_price" decimal(15,2) NOT NULL,
"total_invested" decimal(15,2) NOT NULL,
"current_value" decimal(15,2) DEFAULT NULL,
"profit_loss" decimal(15,2) DEFAULT NULL,
"profit_loss_percent" double precision DEFAULT NULL,
"is_active" boolean NOT NULL DEFAULT TRUE,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_portfolio" PRIMARY KEY ("id"),
CONSTRAINT "fk_portfolio_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE RESTRICT,
CONSTRAINT "fk_portfolio_inventory" FOREIGN KEY ("inventory_id") REFERENCES "trade"."sukuk_inventory"("inventory_id") ON DELETE RESTRICT
);
CREATE TABLE "catalog"."risk_profile_question" (
"id" varchar(191) NOT NULL,
"question" varchar(191) NOT NULL,
"question_number" integer NOT NULL,
"options" jsonb NOT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_risk_profile_question" PRIMARY KEY ("id")
);
CREATE TABLE "catalog"."risk_profile_score_grid" (
"id" varchar(191) NOT NULL,
"risk_level" risk_level_type NOT NULL,
"min_score" integer NOT NULL,
"max_score" integer DEFAULT NULL,
"description" text DEFAULT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_risk_profile_score_grid" PRIMARY KEY ("id")
);
CREATE TABLE "trade"."transaction" (
"id" integer NOT NULL,
"transaction_id" varchar(191) NOT NULL,
"customer_number" varchar(191) NOT NULL,
"inventory_id" varchar(191) NOT NULL,
"transaction_type" transaction_type_enum NOT NULL,
"quantity" integer NOT NULL,
"price_per_unit" decimal(15,2) NOT NULL,
"accrued_interest" decimal(15,2) NOT NULL,
"blox_value" decimal(15,2) NOT NULL,
"total_amount" decimal(15,2) NOT NULL,
"commission" decimal(15,2) NOT NULL,
"currency" varchar(191) NOT NULL,
"wallet_balance_before" decimal(15,2) NOT NULL,
"wallet_balance_after" decimal(15,2) NOT NULL,
"status" status_enum NOT NULL,
"transaction_date" timestamp(3) NOT NULL,
"notes" text DEFAULT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
"totalAmountWithCommission" decimal(15,2) DEFAULT NULL,
"ytc" double precision DEFAULT NULL,
"ytm" double precision DEFAULT NULL,
CONSTRAINT "pk_transaction" PRIMARY KEY ("id"),
CONSTRAINT "uq_transaction_id" UNIQUE ("transaction_id"),
CONSTRAINT "fk_transaction_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE RESTRICT,
CONSTRAINT "fk_transaction_inventory" FOREIGN KEY ("inventory_id") REFERENCES "trade"."sukuk_inventory"("inventory_id") ON DELETE RESTRICT
);
CREATE TABLE "catalog"."user_risk_profile" (
"id" varchar(191) NOT NULL,
"customer_number" varchar(191) NOT NULL,
"total_score" integer NOT NULL,
"risk_level" risk_level_type NOT NULL,
"risk_profile_id" varchar(191) DEFAULT NULL,
"answers" jsonb NOT NULL,
"description" text DEFAULT NULL,
"is_active" boolean NOT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_user_risk_profile" PRIMARY KEY ("id"),
CONSTRAINT "fk_user_risk_profile_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE CASCADE
);
CREATE TABLE "payments"."wallet" (
"id" integer NOT NULL,
"walletId" varchar(191) NOT NULL,
"customer_number" varchar(191) NOT NULL,
"balance" decimal(15,2) NOT NULL DEFAULT 0.00,
"currency" varchar(191) NOT NULL,
"status" walletstauts NOT NULL DEFAULT 'PENDING',
"last_transaction" timestamp(3) DEFAULT NULL,
"is_active" boolean NOT NULL DEFAULT TRUE,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_wallet" PRIMARY KEY ("id"),
CONSTRAINT "uq_wallet_id" UNIQUE ("walletId"),
CONSTRAINT "fk_wallet_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE RESTRICT
);
CREATE TABLE "payments"."wallet_transaction" (
"id" varchar(191) NOT NULL,
"customer_number" varchar(191) NOT NULL,
"transaction_type" wallet_trans_type NOT NULL,
"amount" decimal(15,2) NOT NULL,
"currency" varchar(191) NOT NULL,
"wallet_balance_before" decimal(15,2) NOT NULL,
"wallet_balance_after" decimal(15,2) NOT NULL,
"status" status_enum NOT NULL,
"notes" text DEFAULT NULL,
"processed_by" varchar(191) DEFAULT NULL,
"reference_id" varchar(191) DEFAULT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_wallet_transaction" PRIMARY KEY ("id"),
CONSTRAINT "fk_wallet_transaction_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE RESTRICT
);
CREATE TABLE "payments"."withdrawal" (
"id" integer NOT NULL,
"withdrawal_id" varchar(191) NOT NULL,
"customer_number" varchar(191) NOT NULL,
"bank_verification_id" VARCHAR(191) NOT NULL,
"amount" decimal(15,2) NOT NULL,
"currency" varchar(191) NOT NULL,
"wallet_balance_before" decimal(15,2) NOT NULL,
"wallet_balance_after" decimal(15,2) NOT NULL,
"status" withdrawal_status NOT NULL,
"requested_at" timestamp(3) NOT NULL,
"processed_at" timestamp(3) DEFAULT NULL,
"completed_at" timestamp(3) DEFAULT NULL,
"failed_reason" text DEFAULT NULL,
"admin_notes" text DEFAULT NULL,
"transaction_reference" varchar(191) DEFAULT NULL,
"is_active" boolean NOT NULL DEFAULT TRUE,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_withdrawal" PRIMARY KEY ("id"),
CONSTRAINT "uq_withdrawal_id" UNIQUE ("withdrawal_id"),
CONSTRAINT "fk_withdrawal_user" FOREIGN KEY ("customer_number") REFERENCES "user"."user"("customer_number") ON DELETE RESTRICT,
CONSTRAINT "fk_withdrawal_bank" FOREIGN KEY ("bank_verification_id") REFERENCES "kyc"."bank_verification"("id") ON DELETE RESTRICT
CONSTRAINT "fk_withdrawal_bank_verification_id" FOREIGN KEY ("bank_verification_id") REFERENCES "kyc"."bank_verification"("id"));
-- ============================================================================
-- 7. EXTERNAL INTEGRATION METRIC SYSTEM / CLIENT WIDGET LOCKS
-- ============================================================================
CREATE TABLE "integration"."widget_client" (
"id" varchar(191) NOT NULL,
"name" varchar(191) NOT NULL,
"client_id" varchar(191) NOT NULL,
"api_key_hash" varchar(191) NOT NULL,
"is_active" boolean NOT NULL DEFAULT TRUE,
"allowed_origins" text DEFAULT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_widget_client" PRIMARY KEY ("id"),
CONSTRAINT "uq_widget_client_id" UNIQUE ("client_id")
);
CREATE TABLE "integration"."widget_feature" (
"id" varchar(191) NOT NULL,
"client_id" varchar(191) NOT NULL,
"feature" varchar(191) NOT NULL,
"is_enabled" boolean NOT NULL DEFAULT TRUE,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_widget_feature" PRIMARY KEY ("id"),
CONSTRAINT "fk_widget_feature_client" FOREIGN KEY ("client_id") REFERENCES "integration"."widget_client"("client_id") ON DELETE CASCADE
);
CREATE TABLE "integration"."widget_user_lock" (
"id" varchar(191) NOT NULL,
"client_id" varchar(191) NOT NULL,
"user_id" varchar(191) NOT NULL,
"feature" varchar(191) NOT NULL,
"is_enabled" boolean NOT NULL,
"created_at" timestamp(3) NOT NULL,
"updated_at" timestamp(3) NOT NULL,
CONSTRAINT "pk_widget_user_lock" PRIMARY KEY ("id"),
CONSTRAINT "fk_widget_user_lock_client" FOREIGN KEY ("client_id") REFERENCES "integration"."widget_client"("client_id") ON DELETE CASCADE
);
-- ============================================================================
-- 8. PERFORMANCE TUNING STRATEGY INDEXES (FOREIGN & STATUS CRITERIA)
-- ============================================================================
CREATE INDEX "idx_user_kyc_status" ON "user"("kyc_status");
CREATE INDEX "idx_ticket_status" ON "ticket"("status");
CREATE INDEX "idx_ticket_customer" ON "ticket"("customer_number");
CREATE INDEX "idx_sukuk_price_timestamp" ON "sukuk_price_history"("inventory_id", "timestamp" DESC);
CREATE INDEX "idx_transaction_date" ON "transaction"("transaction_date" DESC);
CREATE INDEX "idx_wallet_trans_customer" ON "wallet_transaction"("customer_number");
CREATE INDEX "idx_portfolio_customer" ON "portfolio"("customer_number");
CREATE INDEX IF NOT EXISTS idx_user_role_active ON "user" ("role", "is_active", "is_deleted");
CREATE INDEX IF NOT EXISTS idx_deposit_batch ON deposit_csv ("batch_id");
CREATE INDEX IF NOT EXISTS idx_deposit_status ON deposit_csv ("status");
CREATE INDEX IF NOT EXISTS idx_sukuk_active_soon ON sukuk_inventory ("is_active", "is_coming_soon");

