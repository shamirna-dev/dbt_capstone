with source as (
    select * from {{ source('raw', 'orders') }}
)

select
    order_id,
    customer_id,
    store_id,
    order_date,
    status,
    status = 'Completed' as is_completed
from source
