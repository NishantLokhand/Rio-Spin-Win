-- Local test users (password = PIN, bcrypt via pgcrypto)
insert into auth.users(id, email, encrypted_password) values
 ('a0000000-0000-0000-0000-000000000001','admin@login.riospinwin.app', extensions.crypt('admin123', extensions.gen_salt('bf'))),
 ('a0000000-0000-0000-0000-000000000002','sup.lucknow@login.riospinwin.app', extensions.crypt('222222', extensions.gen_salt('bf'))),
 ('a0000000-0000-0000-0000-000000000003','9876500001@login.riospinwin.app', extensions.crypt('111111', extensions.gen_salt('bf'))),
 ('a0000000-0000-0000-0000-000000000004','9876500002@login.riospinwin.app', extensions.crypt('111111', extensions.gen_salt('bf'))),
 ('a0000000-0000-0000-0000-000000000005','sup.mumbai@login.riospinwin.app', extensions.crypt('222222', extensions.gen_salt('bf')));
insert into public.app_users(id, role, login_id, full_name, mobile, can_approve_outlets, can_override_cost_target) values
 ('a0000000-0000-0000-0000-000000000001','admin','admin','Campaign Admin',null,true,true),
 ('a0000000-0000-0000-0000-000000000002','supervisor','sup.lucknow','Vikas Tiwari','9000000001',true,false),
 ('a0000000-0000-0000-0000-000000000003','promoter','9876500001','Ravi Kumar','9876500001',false,false),
 ('a0000000-0000-0000-0000-000000000004','promoter','9876500002','Sneha Yadav','9876500002',false,false),
 ('a0000000-0000-0000-0000-000000000005','supervisor','sup.mumbai','Rohan Kulkarni','9000000002',false,false);
insert into public.promoters(user_id, promoter_code, promoter_type, agency_name, supervisor_id, home_state_id) values
 ('a0000000-0000-0000-0000-000000000003','PRM-001','permanent',null,'a0000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001'),
 ('a0000000-0000-0000-0000-000000000004','PRM-002','agency','BrandBuzz Activations','a0000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001');
