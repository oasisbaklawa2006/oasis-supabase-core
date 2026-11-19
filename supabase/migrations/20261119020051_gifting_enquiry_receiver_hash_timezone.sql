-- GFT-100 / Central #677: stable consent hashing across transaction timezone settings.
-- Configuration-only forward correction; preserve applied validation SQL.
ALTER FUNCTION public.gifting_enquiry_receive_v1(text, uuid, jsonb) SET TimeZone = 'UTC';
