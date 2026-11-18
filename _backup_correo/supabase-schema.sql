-- Ejecutar una sola vez en Supabase → SQL Editor.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text not null default '',
  first_name text not null default '',
  last_name text not null default '',
  role text not null check (role in ('student', 'teacher')),
  institution jsonb not null default '{}'::jsonb,
  grade text,
  courses text[] not null default '{}',
  subjects text[] not null default '{}',
  varied_subjects boolean not null default false,
  app_state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
drop policy if exists "Users can read their own profile" on public.profiles;
create policy "Users can read their own profile" on public.profiles
  for select to authenticated using ((select auth.uid()) = id);
drop policy if exists "Users can create their own profile" on public.profiles;
create policy "Users can create their own profile" on public.profiles
  for insert to authenticated with check ((select auth.uid()) = id);
drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile" on public.profiles
  for update to authenticated using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

grant usage on schema public to authenticated;
grant select, insert, update on public.profiles to authenticated;

create table if not exists public.class_memberships (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  teacher_class_id text not null,
  created_at timestamptz not null default now(),
  unique (teacher_id, student_id, teacher_class_id)
);
alter table public.class_memberships enable row level security;
drop policy if exists "Students and teachers can read their class memberships" on public.class_memberships;
create policy "Students and teachers can read their class memberships" on public.class_memberships
  for select to authenticated using ((select auth.uid()) = teacher_id or (select auth.uid()) = student_id);
grant select on public.class_memberships to authenticated;

create or replace function public.find_eligible_students(p_class_id text, p_search text)
returns table(student_id uuid, student_email text, student_name text, student_grade text)
language sql stable security definer set search_path = '' as $$
  select student.id, student.email, student.name, student.grade
  from public.profiles as teacher
  join public.profiles as student on student.role = 'student'
  where teacher.id = (select auth.uid())
    and teacher.role = 'teacher'
    and exists (
      select 1 from jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
      where owned_class.value->>'id' = p_class_id
    )
    and length(trim(coalesce(p_search, ''))) >= 3
    and nullif(trim(teacher.institution->>'department'), '') is not null
    and nullif(trim(teacher.institution->>'municipality'), '') is not null
    and nullif(trim(teacher.institution->>'name'), '') is not null
    and lower(trim(coalesce(student.institution->>'department', ''))) = lower(trim(coalesce(teacher.institution->>'department', '')))
    and lower(trim(coalesce(student.institution->>'municipality', ''))) = lower(trim(coalesce(teacher.institution->>'municipality', '')))
    and lower(trim(coalesce(student.institution->>'area', ''))) = lower(trim(coalesce(teacher.institution->>'area', '')))
    and (
      (nullif(trim(teacher.institution->>'code'), '') is not null
        and student.institution->>'code' = teacher.institution->>'code')
      or (nullif(trim(teacher.institution->>'code'), '') is null
        and nullif(trim(student.institution->>'code'), '') is null
        and lower(trim(coalesce(student.institution->>'name', ''))) = lower(trim(coalesce(teacher.institution->>'name', ''))))
    )
    and (
      position(lower(trim(p_search)) in lower(student.email)) > 0
      or position(lower(trim(p_search)) in lower(student.name)) > 0
    )
    and not exists (
      select 1 from public.class_memberships membership
      where membership.teacher_id = teacher.id
        and membership.student_id = student.id
        and membership.teacher_class_id = p_class_id
    )
  order by student.name
  limit 30;
$$;
revoke all on function public.find_eligible_students(text, text) from public, anon;
grant execute on function public.find_eligible_students(text, text) to authenticated;

create or replace function public.add_student_to_class(p_class_id text, p_student_id uuid)
returns table(student_id uuid, student_email text, student_name text, student_grade text)
language plpgsql security definer set search_path = '' as $$
declare
  teacher public.profiles%rowtype;
  student public.profiles%rowtype;
begin
  select * into teacher from public.profiles where id = (select auth.uid()) and role = 'teacher';
  if teacher.id is null or not exists (
    select 1 from jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
    where owned_class.value->>'id' = p_class_id
  ) then
    raise exception 'No se encontró la clase del docente.';
  end if;

  select * into student from public.profiles where id = p_student_id and role = 'student';
  if student.id is null
    or nullif(trim(teacher.institution->>'department'), '') is null
    or nullif(trim(teacher.institution->>'municipality'), '') is null
    or nullif(trim(teacher.institution->>'name'), '') is null
    or lower(trim(coalesce(student.institution->>'department', ''))) <> lower(trim(coalesce(teacher.institution->>'department', '')))
    or lower(trim(coalesce(student.institution->>'municipality', ''))) <> lower(trim(coalesce(teacher.institution->>'municipality', '')))
    or lower(trim(coalesce(student.institution->>'area', ''))) <> lower(trim(coalesce(teacher.institution->>'area', '')))
    or not (
      (nullif(trim(teacher.institution->>'code'), '') is not null and student.institution->>'code' = teacher.institution->>'code')
      or (nullif(trim(teacher.institution->>'code'), '') is null
        and nullif(trim(student.institution->>'code'), '') is null
        and lower(trim(coalesce(student.institution->>'name', ''))) = lower(trim(coalesce(teacher.institution->>'name', ''))))
    ) then
    raise exception 'El estudiante no pertenece a la misma institución y ubicación.';
  end if;

  insert into public.class_memberships(teacher_id, student_id, teacher_class_id)
  values (teacher.id, student.id, p_class_id)
  on conflict (teacher_id, student_id, teacher_class_id) do nothing;
  return query select student.id, student.email, student.name, student.grade;
end;
$$;
revoke all on function public.add_student_to_class(text, uuid) from public, anon;
grant execute on function public.add_student_to_class(text, uuid) to authenticated;

-- Avisos de apoyo cuando un estudiante deja una lección con avance bajo.
create table if not exists public.teacher_notifications (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  teacher_class_id text not null,
  lesson_key text not null,
  student_name text not null,
  lesson_name text not null,
  subject_name text not null,
  progress integer not null check (progress between 0 and 60),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  unique (teacher_id, student_id, lesson_key)
);
alter table public.teacher_notifications enable row level security;
drop policy if exists "Teachers can read their notifications" on public.teacher_notifications;
create policy "Teachers can read their notifications" on public.teacher_notifications
  for select to authenticated using ((select auth.uid()) = teacher_id);
drop policy if exists "Teachers can mark their notifications read" on public.teacher_notifications;
create policy "Teachers can mark their notifications read" on public.teacher_notifications
  for update to authenticated using ((select auth.uid()) = teacher_id)
  with check ((select auth.uid()) = teacher_id);
grant select, update on public.teacher_notifications to authenticated;

-- Videos que los docentes comparten con sus clases. Los estudiantes autorizados
-- pueden leerlos y descargarlos; los archivos se guardan en Storage privado.
create table if not exists public.class_materials (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  teacher_class_id text not null,
  title text not null,
  description text not null default '',
  grade text not null,
  subject text not null,
  topic text not null,
  file_path text not null unique,
  mime_type text not null,
  file_size bigint not null check (file_size > 0 and file_size <= 52428800),
  created_at timestamptz not null default now()
);
alter table public.class_materials enable row level security;
drop policy if exists "Class members can read class videos" on public.class_materials;
create policy "Class members can read class videos" on public.class_materials
  for select to authenticated using (
    teacher_id = (select auth.uid()) or exists (
      select 1 from public.class_memberships membership
      where membership.teacher_id = class_materials.teacher_id
        and membership.student_id = (select auth.uid())
        and membership.teacher_class_id = class_materials.teacher_class_id
    )
  );
drop policy if exists "Teachers can publish videos to their classes" on public.class_materials;
create policy "Teachers can publish videos to their classes" on public.class_materials
  for insert to authenticated with check (
    teacher_id = (select auth.uid()) and exists (
      select 1 from public.profiles teacher
      where teacher.id = (select auth.uid()) and teacher.role = 'teacher'
        and exists (
          select 1 from jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
          where owned_class.value->>'id' = class_materials.teacher_class_id
        )
    )
  );
drop policy if exists "Teachers can delete their videos" on public.class_materials;
create policy "Teachers can delete their videos" on public.class_materials
  for delete to authenticated using (teacher_id = (select auth.uid()));
grant select, insert, delete on public.class_materials to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('class-videos', 'class-videos', false, 52428800, array['video/mp4','video/webm'])
on conflict (id) do update set public = false, file_size_limit = 52428800, allowed_mime_types = array['video/mp4','video/webm'];
drop policy if exists "Teachers upload their class videos" on storage.objects;
create policy "Teachers upload their class videos" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'class-videos' and split_part(name, '/', 1) = (select auth.uid())::text
    and exists (
      select 1 from public.profiles teacher
      where teacher.id = (select auth.uid()) and teacher.role = 'teacher'
        and exists (
          select 1 from jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
          where owned_class.value->>'id' = split_part(name, '/', 2)
        )
    )
  );
drop policy if exists "Class members can read their videos" on storage.objects;
create policy "Class members can read their videos" on storage.objects
  for select to authenticated using (
    bucket_id = 'class-videos' and (
      split_part(name, '/', 1) = (select auth.uid())::text or exists (
        select 1 from public.class_memberships membership
        where membership.teacher_id::text = split_part(name, '/', 1)
          and membership.student_id = (select auth.uid())
          and membership.teacher_class_id = split_part(name, '/', 2)
      )
    )
  );
drop policy if exists "Teachers delete their class videos" on storage.objects;
create policy "Teachers delete their class videos" on storage.objects
  for delete to authenticated using (bucket_id = 'class-videos' and split_part(name, '/', 1) = (select auth.uid())::text);

create or replace function public.report_low_lesson_progress(
  p_lesson_key text, p_lesson_name text, p_subject_name text, p_progress integer
)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  student public.profiles%rowtype;
  inserted_count integer := 0;
begin
  select * into student from public.profiles where id = (select auth.uid()) and role = 'student';
  if student.id is null then raise exception 'Solo las cuentas de estudiante pueden enviar este aviso.'; end if;
  if p_progress < 0 or p_progress > 60 then raise exception 'El progreso debe estar entre 0 y 60.'; end if;
  if length(trim(coalesce(p_lesson_key, ''))) = 0 or length(trim(coalesce(p_lesson_name, ''))) = 0 then
    raise exception 'Falta identificar la lección.';
  end if;

  insert into public.teacher_notifications (
    teacher_id, student_id, teacher_class_id, lesson_key, student_name, lesson_name, subject_name, progress
  )
  select distinct on (membership.teacher_id) membership.teacher_id, student.id, membership.teacher_class_id, p_lesson_key,
    student.name, p_lesson_name, coalesce(p_subject_name, ''), p_progress
  from public.class_memberships membership
  where membership.student_id = student.id
  order by membership.teacher_id, membership.created_at
  on conflict (teacher_id, student_id, lesson_key)
  do update set progress = excluded.progress;

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;
revoke all on function public.report_low_lesson_progress(text, text, text, integer) from public, anon;
grant execute on function public.report_low_lesson_progress(text, text, text, integer) to authenticated;
