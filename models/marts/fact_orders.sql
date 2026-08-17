with orders as (
    select * from {{ ref('stg_orders') }}
),

order_items as (
    select * from {{ ref('stg_order_items') }}
),

line_level as (
    select
        oi.order_item_id,
        o.order_id,
        o.customer_id,
        o.store_id,
        oi.product_id,
        o.order_date,
        o.status,
        o.is_completed,
        oi.quantity,
        oi.unit_price,
        oi.line_amount
    from order_items oi
    inner join orders o on oi.order_id = o.order_id
)

select
    order_item_id,
    order_id,
    customer_id,
    store_id,
    product_id,
    order_date,
    status,
    is_completed,
    quantity,
    unit_price,
    line_amount as revenue
from line_level
