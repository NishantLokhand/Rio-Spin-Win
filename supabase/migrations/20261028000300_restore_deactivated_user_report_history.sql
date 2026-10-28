-- Keep deactivated users out of live rosters while retaining their historical reports.
delete from public.reporting_excluded_users
 where user_id in (
   '912f9b5d-4949-437a-be67-f383104fb5a8',
   '08d94033-a724-44c4-b351-65cee40e24cd',
   '7c5b82d2-36dd-45a7-85f0-5adbcd3454a7',
   '1cf5df2e-0394-49f4-918f-73c11a4f1bde',
   '5b1616be-3371-4db7-9820-7fc4ce6c7dd7',
   '4ccab1c6-34b7-4076-bfc3-19320fdc5207',
   '556896c6-0795-4983-ae29-8c55a8e274cf'
 );

notify pgrst, 'reload schema';
