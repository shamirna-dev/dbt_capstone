select
    customer_id,
    customer_name,
    email,
    city,
    state,
    segment,
    signup_date
from {{ ref('stg_customers') }}
