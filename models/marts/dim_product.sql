select
    product_id,
    product_name,
    category,
    unit_cost,
    unit_price,
    unit_margin
from {{ ref('stg_products') }}
