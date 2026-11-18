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
#variable_conflict use_column
declare
  v_teacher uuid := (select auth.uid());
  v_grade text;
begin
  if not exists (
    select 1 from public.profiles t
    where t.id = v_teacher and t.role = 'teacher'
      and exists (select 1 from jsonb_array_elements(coalesce(t.app_state->'teacherClasses', '[]'::jsonb)) c where c->>'id' = p_class_id)
  ) then
    raise exception 'No se encontró la clase del docente.';
  end if;

  if not exists (
    select 1
    from public.profiles t
    join public.profiles s on s.id = p_student_id and s.role = 'student'
    where t.id = v_teacher
      and nullif(trim(t.institution->>'department'), '') is not null
      and nullif(trim(t.institution->>'municipality'), '') is not null
      and nullif(trim(t.institution->>'name'), '') is not null
      and lower(trim(coalesce(s.institution->>'department', ''))) = lower(trim(coalesce(t.institution->>'department', '')))
      and lower(trim(coalesce(s.institution->>'municipality', ''))) = lower(trim(coalesce(t.institution->>'municipality', '')))
      and lower(trim(coalesce(s.institution->>'area', ''))) = lower(trim(coalesce(t.institution->>'area', '')))
      and (
        (nullif(trim(t.institution->>'code'), '') is not null and trim(s.institution->>'code') = trim(t.institution->>'code'))
        or (nullif(trim(t.institution->>'code'), '') is null
          and nullif(trim(s.institution->>'code'), '') is null
          and lower(trim(coalesce(s.institution->>'name', ''))) = lower(trim(coalesce(t.institution->>'name', ''))))
      )
  ) then
    raise exception 'El estudiante no pertenece a la misma institución y ubicación.';
  end if;

  insert into public.class_memberships as m (teacher_id, student_id, teacher_class_id)
  values (v_teacher, p_student_id, p_class_id)
  on conflict (teacher_id, student_id, teacher_class_id) do nothing;

  select c->>'grade' into v_grade from public.profiles t, jsonb_array_elements(coalesce(t.app_state->'teacherClasses', '[]'::jsonb)) c where t.id = v_teacher and c->>'id' = p_class_id limit 1;
  if v_grade in ('Primero','Segundo','Tercero','Cuarto','Quinto') then
    update public.profiles s set grade = v_grade where s.id = p_student_id and nullif(trim(coalesce(s.grade,'')),'') is null;
  end if;

  return query select s.id, s.email, s.name, s.grade from public.profiles s where s.id = p_student_id;
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

-- Elimina una clase del docente: inscripciones, avisos y videos (registros) de esa clase.
create or replace function public.delete_teacher_class(p_class_id text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Inicia sesión para eliminar la clase.'; end if;
  delete from public.class_materials where teacher_id = (select auth.uid()) and teacher_class_id = p_class_id;
  delete from public.teacher_notifications where teacher_id = (select auth.uid()) and teacher_class_id = p_class_id;
  delete from public.class_memberships where teacher_id = (select auth.uid()) and teacher_class_id = p_class_id;
end;
$$;
revoke all on function public.delete_teacher_class(text) from public, anon;
grant execute on function public.delete_teacher_class(text) to authenticated;

-- Archivos de actividades: cualquier tipo, máximo 20 MB.
update storage.buckets set allowed_mime_types = null, file_size_limit = 20971520 where id = 'class-videos';

-- Actividades (título, instrucciones y preguntas del docente) de las clases del estudiante.
drop function if exists public.get_my_class_activities();
create function public.get_my_class_activities()
returns table(teacher_class_id text, teacher_name text, class_label text, activities jsonb, joined_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select membership.teacher_class_id,
    teacher.name,
    concat_ws(' ', owned_class.value->>'grade', owned_class.value->>'sectionLabel'),
    coalesce(owned_class.value->'activities', '[]'::jsonb),
    membership.created_at
  from public.class_memberships membership
  join public.profiles teacher on teacher.id = membership.teacher_id
  join lateral jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
    on owned_class.value->>'id' = membership.teacher_class_id
  where membership.student_id = (select auth.uid());
$$;
revoke all on function public.get_my_class_activities() from public, anon;
grant execute on function public.get_my_class_activities() to authenticated;


-- Reglas de cuentas: un correo es docente o estudiante (según su registro), y el perfil se crea al registrarse.
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


-- Progreso real: el docente ve qué actividades completó cada estudiante de sus clases.
create or replace function public.get_class_progress()
returns table(teacher_class_id text, student_id uuid, student_name text, student_email text, student_grade text, done jsonb, last_sync timestamptz)
language sql stable security definer set search_path = '' as $$
  select m.teacher_class_id, s.id, s.name, s.email, s.grade,
         case when jsonb_typeof(s.app_state->'teacherActivitiesDone') = 'array' then s.app_state->'teacherActivitiesDone' else '[]'::jsonb end,
         s.updated_at
  from public.class_memberships m
  join public.profiles s on s.id = m.student_id
  where m.teacher_id = (select auth.uid());
$$;
revoke all on function public.get_class_progress() from public, anon;
grant execute on function public.get_class_progress() to authenticated;


-- ===== Apoyo, actividades especiales y banco de preguntas =====
-- 1) Aviso de apoyo: si el estudiante vuelve a sacar bajo, el aviso se actualiza y vuelve a quedar sin leer.
create or replace function public.report_low_lesson_progress(
  p_lesson_key text, p_lesson_name text, p_subject_name text, p_progress integer
)
returns integer
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_student uuid := (select auth.uid());
  v_name text;
  inserted_count integer := 0;
begin
  select name into v_name from public.profiles where id = v_student and role = 'student';
  if v_name is null then raise exception 'Solo las cuentas de estudiante pueden enviar este aviso.'; end if;
  if p_progress < 0 or p_progress > 60 then raise exception 'El progreso debe estar entre 0 y 60.'; end if;
  if length(trim(coalesce(p_lesson_key, ''))) = 0 or length(trim(coalesce(p_lesson_name, ''))) = 0 then
    raise exception 'Falta identificar la lección.';
  end if;
  insert into public.teacher_notifications as n (teacher_id, student_id, teacher_class_id, lesson_key, student_name, lesson_name, subject_name, progress)
  select distinct on (m.teacher_id) m.teacher_id, v_student, m.teacher_class_id, p_lesson_key, v_name, p_lesson_name, coalesce(p_subject_name, ''), p_progress
  from public.class_memberships m
  where m.student_id = v_student
  order by m.teacher_id, m.created_at
  on conflict (teacher_id, student_id, lesson_key)
  do update set progress = excluded.progress, student_name = excluded.student_name, created_at = now(), read_at = null;
  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

-- 2) Actividades especiales: cada estudiante solo recibe las de toda la clase y las que son para él.
drop function if exists public.get_my_class_activities();
create function public.get_my_class_activities()
returns table(teacher_class_id text, teacher_name text, class_label text, activities jsonb, joined_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select membership.teacher_class_id,
    teacher.name,
    concat_ws(' ', owned_class.value->>'grade', owned_class.value->>'sectionLabel'),
    coalesce((
      select jsonb_agg(act.value)
      from jsonb_array_elements(coalesce(owned_class.value->'activities', '[]'::jsonb)) as act(value)
      where jsonb_typeof(act.value->'assignedTo') is distinct from 'array'
         or jsonb_array_length(act.value->'assignedTo') = 0
         or (act.value->'assignedTo') ? ((select auth.uid())::text)
    ), '[]'::jsonb),
    membership.created_at
  from public.class_memberships membership
  join public.profiles teacher on teacher.id = membership.teacher_id
  join lateral jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
    on owned_class.value->>'id' = membership.teacher_class_id
  where membership.student_id = (select auth.uid());
$$;
revoke all on function public.get_my_class_activities() from public, anon;
grant execute on function public.get_my_class_activities() to authenticated;

-- 3) Banco de preguntas compartido por los docentes.
create table if not exists public.question_bank (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  grade text not null,
  subject text not null,
  topic text not null,
  question text not null check (length(question) between 3 and 300),
  answers jsonb not null check (jsonb_typeof(answers) = 'array' and jsonb_array_length(answers) between 2 and 6),
  correct integer not null check (correct >= 0),
  created_at timestamptz not null default now(),
  unique (teacher_id, grade, subject, topic, question)
);
alter table public.question_bank enable row level security;
drop policy if exists "Teachers add their questions" on public.question_bank;
create policy "Teachers add their questions" on public.question_bank
  for insert to authenticated with check (
    teacher_id = (select auth.uid())
    and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher')
  );
drop policy if exists "Teachers read the shared bank" on public.question_bank;
create policy "Teachers read the shared bank" on public.question_bank
  for select to authenticated using (
    exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher')
  );
drop policy if exists "Teachers delete their questions" on public.question_bank;
create policy "Teachers delete their questions" on public.question_bank
  for delete to authenticated using (teacher_id = (select auth.uid()));
grant select, insert, delete on public.question_bank to authenticated;

create or replace function public.question_bank_summary()
returns table(grade text, subject text, topic text, total bigint, mine bigint)
language sql stable security definer set search_path = '' as $$
  select q.grade, q.subject, q.topic, count(*), count(*) filter (where q.teacher_id = (select auth.uid()))
  from public.question_bank q
  where exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher')
  group by q.grade, q.subject, q.topic
  order by q.grade, q.subject, q.topic;
$$;
revoke all on function public.question_bank_summary() from public, anon;
grant execute on function public.question_bank_summary() to authenticated;
notify pgrst, 'reload schema';


-- Reglas del almacenamiento: "objects.name" (ruta del archivo) va calificado; sin calificar se confundía con profiles.name.
drop policy if exists "Teachers upload their class videos" on storage.objects;
create policy "Teachers upload their class videos" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'class-videos' and split_part(objects.name, '/', 1) = (select auth.uid())::text
    and exists (
      select 1 from public.profiles teacher
      where teacher.id = (select auth.uid()) and teacher.role = 'teacher'
        and exists (
          select 1 from jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
          where owned_class.value->>'id' = split_part(objects.name, '/', 2)
        )
    )
  );
drop policy if exists "Class members can read their videos" on storage.objects;
create policy "Class members can read their videos" on storage.objects
  for select to authenticated using (
    bucket_id = 'class-videos' and (
      split_part(objects.name, '/', 1) = (select auth.uid())::text or exists (
        select 1 from public.class_memberships membership
        where membership.teacher_id::text = split_part(objects.name, '/', 1)
          and membership.student_id = (select auth.uid())
          and membership.teacher_class_id = split_part(objects.name, '/', 2)
      )
    )
  );
drop policy if exists "Teachers delete their class videos" on storage.objects;
create policy "Teachers delete their class videos" on storage.objects
  for delete to authenticated using (bucket_id = 'class-videos' and split_part(objects.name, '/', 1) = (select auth.uid())::text);


-- Foto del docente para el estudiante y puntajes (primer intento) para el promedio real.
drop function if exists public.get_my_class_activities();
create function public.get_my_class_activities()
returns table(teacher_class_id text, teacher_name text, class_label text, activities jsonb, joined_at timestamptz, teacher_avatar text)
language sql stable security definer set search_path = '' as $$
  select membership.teacher_class_id, teacher.name,
    concat_ws(' ', owned_class.value->>'grade', owned_class.value->>'sectionLabel'),
    coalesce((select jsonb_agg(act.value) from jsonb_array_elements(coalesce(owned_class.value->'activities', '[]'::jsonb)) as act(value)
      where jsonb_typeof(act.value->'assignedTo') is distinct from 'array' or jsonb_array_length(act.value->'assignedTo') = 0
         or (act.value->'assignedTo') ? ((select auth.uid())::text)), '[]'::jsonb),
    membership.created_at, teacher.app_state->>'teacherAvatar'
  from public.class_memberships membership
  join public.profiles teacher on teacher.id = membership.teacher_id
  join lateral jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
    on owned_class.value->>'id' = membership.teacher_class_id
  where membership.student_id = (select auth.uid());
$$;
revoke all on function public.get_my_class_activities() from public, anon;
grant execute on function public.get_my_class_activities() to authenticated;
drop function if exists public.get_class_progress();
create function public.get_class_progress()
returns table(teacher_class_id text, student_id uuid, student_name text, student_email text, student_grade text, done jsonb, last_sync timestamptz, scores jsonb)
language sql stable security definer set search_path = '' as $$
  select m.teacher_class_id, s.id, s.name, s.email, s.grade,
    case when jsonb_typeof(s.app_state->'teacherActivitiesDone') = 'array' then s.app_state->'teacherActivitiesDone' else '[]'::jsonb end,
    s.updated_at,
    case when jsonb_typeof(s.app_state->'activityFirstScores') = 'object' then s.app_state->'activityFirstScores' else '{}'::jsonb end
  from public.class_memberships m join public.profiles s on s.id = m.student_id
  where m.teacher_id = (select auth.uid());
$$;
revoke all on function public.get_class_progress() from public, anon;
grant execute on function public.get_class_progress() to authenticated;

-- Progreso: usa el puntaje del primer intento y, si no existe, el mejor puntaje guardado.
create or replace function public.get_class_progress()
returns table(teacher_class_id text, student_id uuid, student_name text, student_email text, student_grade text, done jsonb, last_sync timestamptz, scores jsonb)
language sql stable security definer set search_path = '' as $$
  select m.teacher_class_id, s.id, s.name, s.email, s.grade,
    case when jsonb_typeof(s.app_state->'teacherActivitiesDone') = 'array' then s.app_state->'teacherActivitiesDone' else '[]'::jsonb end,
    s.updated_at,
    (case when jsonb_typeof(s.app_state->'activityScores') = 'object' then s.app_state->'activityScores' else '{}'::jsonb end)
    || (case when jsonb_typeof(s.app_state->'activityFirstScores') = 'object' then s.app_state->'activityFirstScores' else '{}'::jsonb end)
  from public.class_memberships m join public.profiles s on s.id = m.student_id
  where m.teacher_id = (select auth.uid());
$$;

-- Materias de la clase para el estudiante (todas, una o varias, según lo que eligió el docente).
drop function if exists public.get_my_class_activities();
create function public.get_my_class_activities()
returns table(teacher_class_id text, teacher_name text, class_label text, activities jsonb, joined_at timestamptz, teacher_avatar text, class_subjects jsonb)
language sql stable security definer set search_path = '' as $$
  select membership.teacher_class_id, teacher.name,
    concat_ws(' ', owned_class.value->>'grade', owned_class.value->>'sectionLabel'),
    coalesce((select jsonb_agg(act.value) from jsonb_array_elements(coalesce(owned_class.value->'activities', '[]'::jsonb)) as act(value)
      where jsonb_typeof(act.value->'assignedTo') is distinct from 'array' or jsonb_array_length(act.value->'assignedTo') = 0
         or (act.value->'assignedTo') ? ((select auth.uid())::text)), '[]'::jsonb),
    membership.created_at, teacher.app_state->>'teacherAvatar',
    case when jsonb_typeof(owned_class.value->'subjects') = 'array' then owned_class.value->'subjects' else '[]'::jsonb end
  from public.class_memberships membership
  join public.profiles teacher on teacher.id = membership.teacher_id
  join lateral jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
    on owned_class.value->>'id' = membership.teacher_class_id
  where membership.student_id = (select auth.uid());
$$;
revoke all on function public.get_my_class_activities() from public, anon;
grant execute on function public.get_my_class_activities() to authenticated;
