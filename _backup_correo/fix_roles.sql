-- 1) El rol y el correo de cada perfil siempre salen del registro (auth.users).
create or replace function public.enforce_profile_identity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  u_email text;
  u_meta jsonb;
begin
  select email, raw_user_meta_data into u_email, u_meta from auth.users where id = new.id;
  if u_email is not null then new.email := u_email; end if;
  if coalesce(u_meta->>'role', '') in ('student', 'teacher') then new.role := u_meta->>'role'; end if;
  if new.role = 'teacher' then
    new.grade := null;
  elsif nullif(trim(coalesce(new.grade, '')), '') is null and coalesce(u_meta->>'grade', '') in ('Primero','Segundo','Tercero','Cuarto','Quinto') then
    new.grade := u_meta->>'grade';
  end if;
  if (new.institution is null or new.institution = '{}'::jsonb) and jsonb_typeof(u_meta->'institution') = 'object' then
    new.institution := u_meta->'institution';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_enforce_identity on public.profiles;
create trigger profiles_enforce_identity before insert or update on public.profiles
  for each row execute function public.enforce_profile_identity();

-- 2) El perfil se crea en el mismo momento del registro, para que el estudiante aparezca de inmediato.
create or replace function public.create_profile_for_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  if coalesce(m->>'role', '') not in ('student', 'teacher') then return new; end if;
  insert into public.profiles (id, email, name, first_name, last_name, role, institution, grade, courses, subjects, varied_subjects)
  values (
    new.id, new.email, coalesce(m->>'name', ''), coalesce(m->>'first_name', ''), coalesce(m->>'last_name', ''), m->>'role',
    case when jsonb_typeof(m->'institution') = 'object' then m->'institution' else '{}'::jsonb end,
    case when m->>'role' = 'student' then nullif(m->>'grade', '') end,
    case when jsonb_typeof(m->'courses') = 'array' then array(select jsonb_array_elements_text(m->'courses')) else '{}'::text[] end,
    case when jsonb_typeof(m->'subjects') = 'array' then array(select jsonb_array_elements_text(m->'subjects')) else '{}'::text[] end,
    coalesce((m->>'varied_subjects')::boolean, false)
  ) on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile after insert on auth.users
  for each row execute function public.create_profile_for_new_user();
