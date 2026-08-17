{{
    config(materialized='table')
}}

-- Generates a daily date spine for 2023-01-01 .. 2024-12-31 using Snowflake's
-- GENERATOR table function, so no extra dbt packages are required.

with date_spine as (
    select
        dateadd(day, seq4(), '2023-01-01'::date) as date_day
    from table(generator(rowcount => 731))
)

select
    date_day,
    year(date_day) as year,
    quarter(date_day) as quarter,
    month(date_day) as month,
    monthname(date_day) as month_name,
    day(date_day) as day_of_month,
    dayname(date_day) as day_name,
    weekofyear(date_day) as week_of_year,
    case when dayofweek(date_day) in (0, 6) then true else false end as is_weekend
from date_spine
