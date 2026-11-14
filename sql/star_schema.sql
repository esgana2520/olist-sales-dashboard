-- Star schema for the Power BI dashboard.
-- Grain:
--   fact_orders       one row per order (all statuses)
--   fact_order_items  one row per item sold
-- Both facts share the dimensions dim_date and dim_state;
-- fact_order_items also uses dim_product and dim_seller.

-- ---------------------------------------------------------------- dim_state
CREATE TABLE dim_state AS
SELECT * FROM (VALUES
    ('AC', 'Acre', 'North'),               ('AL', 'Alagoas', 'Northeast'),
    ('AP', 'Amapá', 'North'),              ('AM', 'Amazonas', 'North'),
    ('BA', 'Bahia', 'Northeast'),          ('CE', 'Ceará', 'Northeast'),
    ('DF', 'Distrito Federal', 'Central-West'), ('ES', 'Espírito Santo', 'Southeast'),
    ('GO', 'Goiás', 'Central-West'),       ('MA', 'Maranhão', 'Northeast'),
    ('MT', 'Mato Grosso', 'Central-West'), ('MS', 'Mato Grosso do Sul', 'Central-West'),
    ('MG', 'Minas Gerais', 'Southeast'),   ('PA', 'Pará', 'North'),
    ('PB', 'Paraíba', 'Northeast'),        ('PR', 'Paraná', 'South'),
    ('PE', 'Pernambuco', 'Northeast'),     ('PI', 'Piauí', 'Northeast'),
    ('RJ', 'Rio de Janeiro', 'Southeast'), ('RN', 'Rio Grande do Norte', 'Northeast'),
    ('RS', 'Rio Grande do Sul', 'South'),  ('RO', 'Rondônia', 'North'),
    ('RR', 'Roraima', 'North'),            ('SC', 'Santa Catarina', 'South'),
    ('SP', 'São Paulo', 'Southeast'),      ('SE', 'Sergipe', 'Northeast'),
    ('TO', 'Tocantins', 'North')
) AS t(state_code, state_name, region);

-- -------------------------------------------------------------- dim_product
CREATE TABLE dim_product AS
SELECT
    p.product_id,
    replace(COALESCE(t.product_category_name_english, p.product_category_name, 'unknown'), '_', ' ') AS category,
    p.product_weight_g AS weight_g
FROM products p
LEFT JOIN category_translation t ON t.product_category_name = p.product_category_name;

-- --------------------------------------------------------------- dim_seller
CREATE TABLE dim_seller AS
SELECT seller_id, seller_city, seller_state
FROM sellers;

-- -------------------------------------------------------------- fact_orders
CREATE TABLE fact_orders AS
WITH item_totals AS (
    SELECT order_id, SUM(price) AS revenue, SUM(freight_value) AS freight, COUNT(*) AS items
    FROM order_items
    GROUP BY order_id
),
payment AS (
    SELECT
        order_id,
        arg_max(payment_type, payment_value) AS payment_type,
        MAX(payment_installments)            AS installments,
        SUM(payment_value)                   AS payment_value
    FROM order_payments
    GROUP BY order_id
),
review AS (
    -- an order can have several reviews: keep the most recent
    SELECT order_id, review_score
    FROM (
        SELECT order_id, review_score,
               ROW_NUMBER() OVER (PARTITION BY order_id
                                  ORDER BY CAST(review_answer_timestamp AS TIMESTAMP) DESC) AS rn
        FROM order_reviews
    )
    WHERE rn = 1
),
base AS (
    SELECT
        o.order_id,
        c.customer_unique_id,
        c.customer_state,
        o.order_status,
        CAST(o.order_purchase_timestamp AS TIMESTAMP)      AS purchased_at,
        CAST(o.order_delivered_customer_date AS TIMESTAMP) AS delivered_at,
        CAST(o.order_estimated_delivery_date AS TIMESTAMP) AS estimated_at
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
)
SELECT
    b.order_id,
    b.customer_unique_id,
    b.customer_state,
    b.order_status,
    CAST(b.purchased_at AS DATE)                                   AS order_date,
    hour(b.purchased_at)                                           AS order_hour,
    CAST(b.delivered_at AS DATE)                                   AS delivered_date,
    CAST(b.estimated_at AS DATE)                                   AS estimated_delivery_date,
    date_diff('day', b.purchased_at, b.delivered_at)               AS delivery_days,
    CASE WHEN b.delivered_at IS NULL THEN NULL
         WHEN b.delivered_at > b.estimated_at THEN 1 ELSE 0 END    AS is_late,
    CASE
        WHEN b.delivered_at IS NULL                                  THEN NULL
        WHEN b.delivered_at <= b.estimated_at                        THEN '1. On time or early'
        WHEN date_diff('day', b.estimated_at, b.delivered_at) <= 3   THEN '2. 1-3 days late'
        WHEN date_diff('day', b.estimated_at, b.delivered_at) <= 7   THEN '3. 4-7 days late'
        ELSE '4. More than 7 days late'
    END                                                            AS delivery_bucket,
    COALESCE(i.revenue, 0)                                         AS revenue,
    COALESCE(i.freight, 0)                                         AS freight,
    COALESCE(i.items, 0)                                           AS items,
    p.payment_type,
    p.installments,
    p.payment_value,
    r.review_score,
    -- order sequence per customer, counting delivered orders only
    CASE WHEN b.order_status = 'delivered' THEN
        ROW_NUMBER() OVER (PARTITION BY b.customer_unique_id, b.order_status ORDER BY b.purchased_at)
    END                                                            AS customer_order_number
FROM base b
LEFT JOIN item_totals i ON i.order_id = b.order_id
LEFT JOIN payment p     ON p.order_id = b.order_id
LEFT JOIN review r      ON r.order_id = b.order_id;

-- --------------------------------------------------------- fact_order_items
CREATE TABLE fact_order_items AS
SELECT
    i.order_id,
    i.order_item_id,
    i.product_id,
    i.seller_id,
    f.order_date,
    f.customer_state,
    f.order_status,
    i.price,
    i.freight_value
FROM order_items i
JOIN fact_orders f ON f.order_id = i.order_id;

-- ----------------------------------------------------------------- dim_date
CREATE TABLE dim_date AS
WITH bounds AS (
    SELECT date_trunc('year', MIN(order_date)) AS first_day,
           date_trunc('year', MAX(order_date)) + INTERVAL 1 YEAR - INTERVAL 1 DAY AS last_day
    FROM fact_orders
)
SELECT
    CAST(d AS DATE)                    AS date,
    year(d)                            AS year,
    quarter(d)                         AS quarter,
    'Q' || quarter(d)                  AS quarter_label,
    month(d)                           AS month_number,
    strftime(d, '%b')                  AS month_name,
    strftime(d, '%Y-%m')               AS year_month,
    year(d) * 100 + month(d)           AS year_month_sort,
    isodow(d)                          AS weekday_number,
    strftime(d, '%a')                  AS weekday_name
FROM bounds, generate_series(first_day, last_day, INTERVAL 1 DAY) AS s(d);
