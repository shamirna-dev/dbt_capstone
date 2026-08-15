with source as (
    select * from {{ source('raw', 'customers') }}
)

select
    customer_id,
    first_name,
    last_name,
    first_name || ' ' || last_name as customer_name,
    email,
    city,
    state,
    segment,
    signup_date
from source
