with source as (
    select * from {{ source('raw', 'products') }}
)

select
    product_id,
    product_name,
    category,
    unit_cost,
    unit_price,
    round(unit_price - unit_cost, 2) as unit_margin
from source
