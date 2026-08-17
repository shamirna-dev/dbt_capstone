select
    store_id,
    store_name,
    city,
    state,
    channel
from {{ ref('stg_stores') }}
