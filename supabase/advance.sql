-- Run after the seed when loading a real project: brings the demo clock, and
-- every date in the data, from the seed's 20 November 2026 to today.
select advance_demo_clock() as days_moved, demo_now() as demo_now;
