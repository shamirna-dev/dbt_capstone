with source as (
    select * from {{ source('raw', 'stores') }}
)

select
    store_id,
    store_name,
    city,
    state,
    channel
from source
