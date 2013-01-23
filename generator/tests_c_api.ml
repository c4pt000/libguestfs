(* libguestfs
 * Copyright (C) 2009-2013 Red Hat Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 *)

(* Please read generator/README first. *)

open Printf

open Types
open Utils
open Pr
open Docstrings
open Optgroups
open Actions
open Structs

(* Generate the tests. *)
let rec generate_tests () =
  generate_header CStyle GPLv2plus;

  pr "\
#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <fcntl.h>

#include \"guestfs.h\"

#define STREQ(a,b) (strcmp((a),(b)) == 0)
//#define STRCASEEQ(a,b) (strcasecmp((a),(b)) == 0)
#define STRNEQ(a,b) (strcmp((a),(b)) != 0)
//#define STRCASENEQ(a,b) (strcasecmp((a),(b)) != 0)
//#define STREQLEN(a,b,n) (strncmp((a),(b),(n)) == 0)
//#define STRCASEEQLEN(a,b,n) (strncasecmp((a),(b),(n)) == 0)
#define STRNEQLEN(a,b,n) (strncmp((a),(b),(n)) != 0)
//#define STRCASENEQLEN(a,b,n) (strncasecmp((a),(b),(n)) != 0)
//#define STRPREFIX(a,b) (strncmp((a),(b),strlen((b))) == 0)

static guestfs_h *g;

/* FIXME: nearly identical code appears in fish.c */
static void
print_strings (char *const *argv)
{
  size_t argc;

  for (argc = 0; argv[argc] != NULL; ++argc)
    printf (\"\\t%%s\\n\", argv[argc]);
}

static int
is_available (const char *group)
{
  const char *groups[] = { group, NULL };
  int r;

  guestfs_push_error_handler (g, NULL, NULL);
  r = guestfs_available (g, (char **) groups);
  guestfs_pop_error_handler (g);

  return r == 0;
}

static void
incr (guestfs_h *g, void *iv)
{
  int *i = (int *) iv;
  (*i)++;
}

/* Get md5sum of the named file. */
static void
md5sum (const char *filename, char *result)
{
  char cmd[256];
  snprintf (cmd, sizeof cmd, \"md5sum %%s\", filename);
  FILE *pp = popen (cmd, \"r\");
  if (pp == NULL) {
    perror (cmd);
    exit (EXIT_FAILURE);
  }
  if (fread (result, 1, 32, pp) != 32) {
    perror (\"md5sum: fread\");
    exit (EXIT_FAILURE);
  }
  if (pclose (pp) != 0) {
    perror (\"pclose\");
    exit (EXIT_FAILURE);
  }
  result[32] = '\\0';
}

/* Return the value for a key in a hashtable.
 * Note: the return value is part of the hash and should not be freed.
 */
static const char *
get_key (char **hash, const char *key)
{
  size_t i;

  for (i = 0; hash[i] != NULL; i += 2) {
    if (STREQ (hash[i], key))
      return hash[i+1];
  }

  return NULL; /* key not found */
}

static void
next_test (guestfs_h *g, size_t test_num, size_t nr_tests,
           const char *test_name)
{
  if (guestfs_get_verbose (g))
    printf (\"-------------------------------------------------------------------------------\\n\");
  printf (\"%%3zu/%%3zu %%s\\n\", test_num, nr_tests, test_name);
}

";

  (* Generate a list of commands which are not tested anywhere. *)
  pr "static void\n";
  pr "no_test_warnings (void)\n";
  pr "{\n";
  pr "  size_t i;\n";
  pr "  const char *no_tests[] = {\n";

  let hash : (string, bool) Hashtbl.t = Hashtbl.create 13 in
  List.iter (
    fun { tests = tests } ->
      let tests = filter_map (
        function
        | (_, (Always|If _|Unless _|IfAvailable _), test) -> Some test
        | (_, Disabled, _) -> None
      ) tests in
      let seq = List.concat (List.map seq_of_test tests) in
      let cmds_tested = List.map List.hd seq in
      List.iter (fun cmd -> Hashtbl.replace hash cmd true) cmds_tested
  ) all_functions;

  List.iter (
    fun { name = name } ->
      if not (Hashtbl.mem hash name) then
        pr "    \"%s\",\n" name
  ) all_functions_sorted;

  pr "    NULL\n";
  pr "  };\n";
  pr "\n";
  pr "  for (i = 0; no_tests[i] != NULL; ++i)\n";
  pr "    fprintf (stderr, \"warning: \\\"guestfs_%%s\\\" has no tests\\n\",\n";
  pr "             no_tests[i]);\n";
  pr "}\n";
  pr "\n";

  (* Generate the actual tests.  Note that we generate the tests
   * in reverse order, deliberately, so that (in general) the
   * newest tests run first.  This makes it quicker and easier to
   * debug them.
   *)
  let test_names =
    List.map (
      fun { name = name; optional = optional; tests = tests } ->
        mapi (generate_one_test name optional) tests
    ) (List.rev all_functions) in
  let test_names = List.concat test_names in
  let nr_tests = List.length test_names in

  pr "\
int
main (int argc, char *argv[])
{
  const char *filename;
  int fd;
  const size_t nr_tests = %d;
  size_t test_num = 0;
  size_t nr_failed = 0;

  setbuf (stdout, NULL);

  no_test_warnings ();

  g = guestfs_create ();
  if (g == NULL) {
    printf (\"guestfs_create FAILED\\n\");
    exit (EXIT_FAILURE);
  }

  filename = \"test1.img\";
  fd = open (filename, O_WRONLY|O_CREAT|O_NOCTTY|O_TRUNC|O_CLOEXEC, 0666);
  if (fd == -1) {
    perror (filename);
    exit (EXIT_FAILURE);
  }
  if (ftruncate (fd, %d) == -1) {
    perror (\"ftruncate\");
    close (fd);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (close (fd) == -1) {
    perror (filename);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (guestfs_add_drive (g, filename) == -1) {
    printf (\"guestfs_add_drive %%s FAILED\\n\", filename);
    exit (EXIT_FAILURE);
  }

  filename = \"test2.img\";
  fd = open (filename, O_WRONLY|O_CREAT|O_NOCTTY|O_TRUNC|O_CLOEXEC, 0666);
  if (fd == -1) {
    perror (filename);
    exit (EXIT_FAILURE);
  }
  if (ftruncate (fd, %d) == -1) {
    perror (\"ftruncate\");
    close (fd);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (close (fd) == -1) {
    perror (filename);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (guestfs_add_drive (g, filename) == -1) {
    printf (\"guestfs_add_drive %%s FAILED\\n\", filename);
    exit (EXIT_FAILURE);
  }

  filename = \"test3.img\";
  fd = open (filename, O_WRONLY|O_CREAT|O_NOCTTY|O_TRUNC|O_CLOEXEC, 0666);
  if (fd == -1) {
    perror (filename);
    exit (EXIT_FAILURE);
  }
  if (ftruncate (fd, %d) == -1) {
    perror (\"ftruncate\");
    close (fd);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (close (fd) == -1) {
    perror (filename);
    unlink (filename);
    exit (EXIT_FAILURE);
  }
  if (guestfs_add_drive (g, filename) == -1) {
    printf (\"guestfs_add_drive %%s FAILED\\n\", filename);
    exit (EXIT_FAILURE);
  }

  if (guestfs_add_drive_ro (g, \"../data/test.iso\") == -1) {
    printf (\"guestfs_add_drive_ro ../data/test.iso FAILED\\n\");
    exit (EXIT_FAILURE);
  }

  /* Set a timeout in case qemu hangs during launch (RHBZ#505329). */
  alarm (600);

  if (guestfs_launch (g) == -1) {
    printf (\"guestfs_launch FAILED\\n\");
    exit (EXIT_FAILURE);
  }

  /* Cancel previous alarm. */
  alarm (0);

  /* Create ext2 filesystem on /dev/sdb1 partition. */
  if (guestfs_part_disk (g, \"/dev/sdb\", \"mbr\") == -1) {
    printf (\"guestfs_part_disk FAILED\\n\");
    exit (EXIT_FAILURE);
  }
  if (guestfs_mkfs (g, \"ext2\", \"/dev/sdb1\") == -1) {
    printf (\"guestfs_mkfs (/dev/sdb1) FAILED\\n\");
    exit (EXIT_FAILURE);
  }

" nr_tests (500 * 1024 * 1024) (50 * 1024 * 1024) (10 * 1024 * 1024);

  iteri (
    fun i test_name ->
      pr "  test_num++;\n";
      pr "  next_test (g, test_num, nr_tests, \"%s\");\n" test_name;
      pr "  if (%s () == -1) {\n" test_name;
      pr "    printf (\"%%s FAILED\\n\", \"%s\");\n" test_name;
      pr "    nr_failed++;\n";
      pr "  }\n";
  ) test_names;
  pr "\n";

  pr "  /* Check close callback is called. */
  int close_sentinel = 1;
  guestfs_set_close_callback (g, incr, &close_sentinel);

  guestfs_close (g);

  if (close_sentinel != 2) {
    fprintf (stderr, \"close callback was not called\\n\");
    exit (EXIT_FAILURE);
  }

  unlink (\"test1.img\");
  unlink (\"test2.img\");
  unlink (\"test3.img\");

";

  pr "  if (nr_failed > 0) {\n";
  pr "    printf (\"***** %%zu / %%zu tests FAILED *****\\n\", nr_failed, nr_tests);\n";
  pr "    exit (EXIT_FAILURE);\n";
  pr "  }\n";
  pr "\n";

  pr "  exit (EXIT_SUCCESS);\n";
  pr "}\n"

and generate_one_test name optional i (init, prereq, test) =
  let test_name = sprintf "test_%s_%d" name i in

  pr "\
static int
%s_skip (void)
{
  const char *str;

  str = getenv (\"TEST_ONLY\");
  if (str)
    return strstr (str, \"%s\") == NULL;
  str = getenv (\"SKIP_%s\");
  if (str && STREQ (str, \"1\")) return 1;
  str = getenv (\"SKIP_TEST_%s\");
  if (str && STREQ (str, \"1\")) return 1;
  return 0;
}

" test_name name (String.uppercase test_name) (String.uppercase name);

  (match prereq with
   | Disabled | Always | IfAvailable _ -> ()
   | If code | Unless code ->
       pr "static int\n";
       pr "%s_prereq (void)\n" test_name;
       pr "{\n";
       pr "  %s\n" code;
       pr "}\n";
       pr "\n";
  );

  pr "\
static int
%s (void)
{
  if (%s_skip ()) {
    printf (\"        %%s skipped (reason: environment variable set)\\n\", \"%s\");
    return 0;
  }

" test_name test_name test_name;

  (* Optional functions should only be tested if the relevant
   * support is available in the daemon.
   *)
  (match optional with
  | Some group ->
    pr "  if (!is_available (\"%s\")) {\n" group;
    pr "    printf (\"        %%s skipped (reason: group %%s not available in daemon)\\n\", \"%s\", \"%s\");\n" test_name group;
    pr "    return 0;\n";
    pr "  }\n";
  | None -> ()
  );

  (match prereq with
   | Disabled ->
       pr "  printf (\"        %%s skipped (reason: test disabled in generator)\\n\", \"%s\");\n" test_name
   | If _ ->
       pr "  if (! %s_prereq ()) {\n" test_name;
       pr "    printf (\"        %%s skipped (reason: test prerequisite)\\n\", \"%s\");\n" test_name;
       pr "    return 0;\n";
       pr "  }\n";
       pr "\n";
       generate_one_test_body name i test_name init test;
   | Unless _ ->
       pr "  if (%s_prereq ()) {\n" test_name;
       pr "    printf (\"        %%s skipped (reason: test prerequisite)\\n\", \"%s\");\n" test_name;
       pr "    return 0;\n";
       pr "  }\n";
       pr "\n";
       generate_one_test_body name i test_name init test;
   | IfAvailable group ->
       pr "  if (!is_available (\"%s\")) {\n" group;
       pr "    printf (\"        %%s skipped (reason: %%s not available)\\n\", \"%s\", \"%s\");\n" test_name group;
       pr "    return 0;\n";
       pr "  }\n";
       pr "\n";
       generate_one_test_body name i test_name init test;
   | Always ->
       generate_one_test_body name i test_name init test
  );

  pr "  return 0;\n";
  pr "}\n";
  pr "\n";
  test_name

and generate_one_test_body name i test_name init test =
  (match init with
   | InitNone (* XXX at some point, InitNone and InitEmpty became
               * folded together as the same thing.  Really we should
               * make InitNone do nothing at all, but the tests may
               * need to be checked to make sure this is OK.
               *)
   | InitEmpty ->
       pr "  /* InitNone|InitEmpty for %s */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"]]
   | InitPartition ->
       pr "  /* InitPartition for %s: create /dev/sda1 */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["part_disk"; "/dev/sda"; "mbr"]]
   | InitGPT ->
       pr "  /* InitGPT for %s: create /dev/sda1 */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["part_disk"; "/dev/sda"; "gpt"]]
   | InitBasicFS ->
       pr "  /* InitBasicFS for %s: create ext2 on /dev/sda1 */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["part_disk"; "/dev/sda"; "mbr"];
          ["mkfs"; "ext2"; "/dev/sda1"; ""; "NOARG"; ""; ""];
          ["mount"; "/dev/sda1"; "/"]]
   | InitBasicFSonLVM ->
       pr "  /* InitBasicFSonLVM for %s: create ext2 on /dev/VG/LV */\n"
         test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["part_disk"; "/dev/sda"; "mbr"];
          ["pvcreate"; "/dev/sda1"];
          ["vgcreate"; "VG"; "/dev/sda1"];
          ["lvcreate"; "LV"; "VG"; "8"];
          ["mkfs"; "ext2"; "/dev/VG/LV"; ""; "NOARG"; ""; ""];
          ["mount"; "/dev/VG/LV"; "/"]]
   | InitISOFS ->
       pr "  /* InitISOFS for %s */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["mount_ro"; "/dev/sdd"; "/"]]
   | InitScratchFS ->
       pr "  /* InitScratchFS for %s */\n" test_name;
       List.iter (generate_test_command_call test_name)
         [["blockdev_setrw"; "/dev/sda"];
          ["umount_all"];
          ["lvm_remove_all"];
          ["mount"; "/dev/sdb1"; "/"]]
  );

  let get_seq_last = function
    | [] ->
        failwithf "%s: you cannot use [] (empty list) when expecting a command"
          test_name
    | seq ->
        let seq = List.rev seq in
        List.rev (List.tl seq), List.hd seq
  in

  match test with
  | TestRun seq ->
      pr "  /* TestRun for %s (%d) */\n" name i;
      List.iter (generate_test_command_call test_name) seq
  | TestOutput (seq, expected) ->
      pr "  /* TestOutput for %s (%d) */\n" name i;
      pr "  const char *expected = \"%s\";\n" (c_quote expected);
      let seq, last = get_seq_last seq in
      let test () =
        pr "    if (STRNEQ (r, expected)) {\n";
        pr "      fprintf (stderr, \"%%s: expected \\\"%%s\\\" but got \\\"%%s\\\"\\n\", \"%s\", expected, r);\n" test_name;
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputList (seq, expected) ->
      pr "  /* TestOutputList for %s (%d) */\n" name i;
      let seq, last = get_seq_last seq in
      let test () =
        iteri (
          fun i str ->
            pr "    if (!r[%d]) {\n" i;
            pr "      fprintf (stderr, \"%%s: short list returned from command\\n\", \"%s\");\n" test_name;
            pr "      print_strings (r);\n";
            pr "      return -1;\n";
            pr "    }\n";
            pr "    {\n";
            pr "      const char *expected = \"%s\";\n" (c_quote str);
            pr "      if (STRNEQ (r[%d], expected)) {\n" i;
            pr "        fprintf (stderr, \"%%s: expected \\\"%%s\\\" but got \\\"%%s\\\"\\n\", \"%s\", expected, r[%d]);\n" test_name i;
            pr "        return -1;\n";
            pr "      }\n";
            pr "    }\n"
        ) expected;
        pr "    if (r[%d] != NULL) {\n" (List.length expected);
        pr "      fprintf (stderr, \"%%s: extra elements returned from command\\n\", \"%s\");\n" test_name;
        pr "      print_strings (r);\n";
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputListOfDevices (seq, expected) ->
      pr "  /* TestOutputListOfDevices for %s (%d) */\n" name i;
      let seq, last = get_seq_last seq in
      let test () =
        iteri (
          fun i str ->
            pr "    if (!r[%d]) {\n" i;
            pr "      fprintf (stderr, \"%%s: short list returned from command\\n\", \"%s\");\n" test_name;
            pr "      print_strings (r);\n";
            pr "      return -1;\n";
            pr "    }\n";
            pr "    {\n";
            pr "      const char *expected = \"%s\";\n" (c_quote str);
            pr "      r[%d][5] = 's';\n" i;
            pr "      if (STRNEQ (r[%d], expected)) {\n" i;
            pr "        fprintf (stderr, \"%%s: expected \\\"%%s\\\" but got \\\"%%s\\\"\\n\", \"%s\", expected, r[%d]);\n" test_name i;
            pr "        return -1;\n";
            pr "      }\n";
            pr "    }\n"
        ) expected;
        pr "    if (r[%d] != NULL) {\n" (List.length expected);
        pr "      fprintf (stderr, \"%%s: extra elements returned from command\\n\", \"%s\");\n" test_name;
        pr "      print_strings (r);\n";
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputInt (seq, expected) ->
      pr "  /* TestOutputInt for %s (%d) */\n" name i;
      let seq, last = get_seq_last seq in
      let test () =
        pr "    if (r != %d) {\n" expected;
        pr "      fprintf (stderr, \"%%s: expected %d but got %%d\\n\","
          expected;
        pr "               \"%s\", (int) r);\n" test_name;
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputIntOp (seq, op, expected) ->
      pr "  /* TestOutputIntOp for %s (%d) */\n" name i;
      let seq, last = get_seq_last seq in
      let test () =
        pr "    if (! (r %s %d)) {\n" op expected;
        pr "      fprintf (stderr, \"%%s: expected %s %d but got %%d\\n\","
          op expected;
        pr "               \"%s\", (int) r);\n" test_name;
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputTrue seq ->
      pr "  /* TestOutputTrue for %s (%d) */\n" name i;
      let seq, last = get_seq_last seq in
      let test () =
        pr "    if (!r) {\n";
        pr "      fprintf (stderr, \"%%s: expected true, got false\\n\", \"%s\");\n" test_name;
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputFalse seq ->
      pr "  /* TestOutputFalse for %s (%d) */\n" name i;
      let seq, last = get_seq_last seq in
      let test () =
        pr "    if (r) {\n";
        pr "      fprintf (stderr, \"%%s: expected false, got true\\n\", \"%s\");\n" test_name;
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputLength (seq, expected) ->
      pr "  /* TestOutputLength for %s (%d) */\n" name i;
      let seq, last = get_seq_last seq in
      let test () =
        pr "    int j;\n";
        pr "    for (j = 0; j < %d; ++j)\n" expected;
        pr "      if (r[j] == NULL) {\n";
        pr "        fprintf (stderr, \"%%s: short list returned\\n\", \"%s\");\n" test_name;
        pr "        print_strings (r);\n";
        pr "        return -1;\n";
        pr "      }\n";
        pr "    if (r[j] != NULL) {\n";
        pr "      fprintf (stderr, \"%%s: long list returned\\n\", \"%s\");\n"
          test_name;
        pr "      print_strings (r);\n";
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputBuffer (seq, expected) ->
      pr "  /* TestOutputBuffer for %s (%d) */\n" name i;
      pr "  const char *expected = \"%s\";\n" (c_quote expected);
      let seq, last = get_seq_last seq in
      let len = String.length expected in
      let test () =
        pr "    if (size != %d) {\n" len;
        pr "      fprintf (stderr, \"%%s: returned size of buffer wrong, expected %d but got %%zu\\n\", \"%s\", size);\n" len test_name;
        pr "      return -1;\n";
        pr "    }\n";
        pr "    if (STRNEQLEN (r, expected, size)) {\n";
        pr "      fprintf (stderr, \"%%s: expected \\\"%%s\\\" but got \\\"%%s\\\"\\n\", \"%s\", expected, r);\n" test_name;
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputStruct (seq, checks) ->
      pr "  /* TestOutputStruct for %s (%d) */\n" name i;
      let seq, last = get_seq_last seq in
      let test () =
        List.iter (
          function
          | CompareWithInt (field, expected) ->
              pr "    if (r->%s != %d) {\n" field expected;
              pr "      fprintf (stderr, \"%%s: %s was %%d, expected %d\\n\",\n"
                field expected;
              pr "               \"%s\", (int) r->%s);\n" test_name field;
              pr "      return -1;\n";
              pr "    }\n"
          | CompareWithIntOp (field, op, expected) ->
              pr "    if (!(r->%s %s %d)) {\n" field op expected;
              pr "      fprintf (stderr, \"%%s: %s was %%d, expected %s %d\\n\",\n"
                field op expected;
              pr "               \"%s\", (int) r->%s);\n" test_name field;
              pr "      return -1;\n";
              pr "    }\n"
          | CompareWithString (field, expected) ->
              pr "    if (STRNEQ (r->%s, \"%s\")) {\n" field expected;
              pr "      fprintf (stderr, \"%%s: %s was \\\"%%s\\\", expected \\\"%s\\\"\\n\",\n"
                field expected;
              pr "               \"%s\", r->%s);\n" test_name field;
              pr "      return -1;\n";
              pr "    }\n"
          | CompareFieldsIntEq (field1, field2) ->
              pr "    if (r->%s != r->%s) {\n" field1 field2;
              pr "      fprintf (stderr, \"%s: %s (%%d) <> %s (%%d)\\n\",\n"
                test_name field1 field2;
              pr "               (int) r->%s, (int) r->%s);\n" field1 field2;
              pr "      return -1;\n";
              pr "    }\n"
          | CompareFieldsStrEq (field1, field2) ->
              pr "    if (STRNEQ (r->%s, r->%s)) {\n" field1 field2;
              pr "      fprintf (stderr, \"%s: %s (\"%%s\") <> %s (\"%%s\")\\n\",\n"
                test_name field1 field2;
              pr "               r->%s, r->%s);\n" field1 field2;
              pr "      return -1;\n";
              pr "    }\n"
        ) checks
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputFileMD5 (seq, filename) ->
      pr "  /* TestOutputFileMD5 for %s (%d) */\n" name i;
      pr "  char expected[33];\n";
      pr "  md5sum (\"%s\", expected);\n" filename;
      let seq, last = get_seq_last seq in
      let test () =
        pr "    if (STRNEQ (r, expected)) {\n";
        pr "      fprintf (stderr, \"%%s: expected \\\"%%s\\\" but got \\\"%%s\\\"\\n\", \"%s\", expected, r);\n" test_name;
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputDevice (seq, expected) ->
      pr "  /* TestOutputDevice for %s (%d) */\n" name i;
      pr "  const char *expected = \"%s\";\n" (c_quote expected);
      let seq, last = get_seq_last seq in
      let test () =
        pr "    r[5] = 's';\n";
        pr "    if (STRNEQ (r, expected)) {\n";
        pr "      fprintf (stderr, \"%%s: expected \\\"%%s\\\" but got \\\"%%s\\\"\\n\", \"%s\", expected, r);\n" test_name;
        pr "      return -1;\n";
        pr "    }\n"
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestOutputHashtable (seq, fields) ->
      pr "  /* TestOutputHashtable for %s (%d) */\n" name i;
      pr "  const char *key, *expected, *value;\n";
      let seq, last = get_seq_last seq in
      let test () =
        List.iter (
          fun (key, value) ->
            pr "    key = \"%s\";\n" (c_quote key);
            pr "    expected = \"%s\";\n" (c_quote value);
            pr "    value = get_key (r, key);\n";
            pr "    if (value == NULL) {\n";
            pr "      fprintf (stderr, \"%%s: key \\\"%%s\\\" not found in hash: expecting \\\"%%s\\\"\\n\", \"%s\", key, expected);\n" test_name;
            pr "      return -1;\n";
            pr "    }\n";
            pr "    if (STRNEQ (value, expected)) {\n";
            pr "      fprintf (stderr, \"%%s: key \\\"%%s\\\": expected \\\"%%s\\\" but got \\\"%%s\\\"\\n\", \"%s\", key, expected, value);\n" test_name;
            pr "      return -1;\n";
            pr "    }\n";
        ) fields
      in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call ~test test_name last
  | TestLastFail seq ->
      pr "  /* TestLastFail for %s (%d) */\n" name i;
      let seq, last = get_seq_last seq in
      List.iter (generate_test_command_call test_name) seq;
      generate_test_command_call test_name ~expect_error:true last

(* Generate the code to run a command, leaving the result in 'r'.
 * If you expect to get an error then you should set expect_error:true.
 *)
and generate_test_command_call ?(expect_error = false) ?test test_name cmd =
  match cmd with
  | [] -> assert false
  | name :: args ->
      (* Look up the function. *)
      let f =
        try List.find (fun { name = n } -> n = name) all_functions
        with Not_found ->
          failwithf "%s: in test, command %s was not found" test_name name in

      (* Look up the arguments and return type. *)
      let style_ret, style_args, style_optargs = f.style in

      (* Match up the arguments strings and argument types. *)
      let args, optargs =
        let rec loop argts args =
          match argts, args with
          | (t::ts), (s::ss) ->
              let args, rest = loop ts ss in
              ((t, s) :: args), rest
          | [], ss -> [], ss
          | ts, [] ->
              failwithf "%s: in test, too few args given to function %s"
                test_name name
        in
        let args, optargs = loop style_args args in
        let optargs, rest = loop style_optargs optargs in
        if rest <> [] then
          failwithf "%s: in test, too many args given to function %s"
            test_name name;
        args, optargs in

      pr "  {\n";

      List.iter (
        function
        | OptString n, "NULL" -> ()
        | Pathname n, arg
        | Device n, arg
        | Mountable n, arg
        | Dev_or_Path n, arg
        | String n, arg
        | OptString n, arg
        | Key n, arg ->
            pr "    const char *%s = \"%s\";\n" n (c_quote arg);
        | BufferIn n, arg ->
            pr "    const char *%s = \"%s\";\n" n (c_quote arg);
            pr "    size_t %s_size = %d;\n" n (String.length arg)
        | Int _, _
        | Int64 _, _
        | Bool _, _
        | FileIn _, _ | FileOut _, _ -> ()
        | StringList n, "" | DeviceList n, "" ->
            pr "    const char *const %s[1] = { NULL };\n" n
        | StringList n, arg | DeviceList n, arg ->
            let strs = string_split " " arg in
            iteri (
              fun i str ->
                pr "    const char *%s_%d = \"%s\";\n" n i (c_quote str);
            ) strs;
            pr "    const char *const %s[] = {\n" n;
            iteri (
              fun i _ -> pr "      %s_%d,\n" n i
            ) strs;
            pr "      NULL\n";
            pr "    };\n";
        | Pointer _, _ ->
            (* Difficult to make these pointers in order to run a test. *)
            assert false
      ) args;

      if optargs <> [] then (
        pr "    struct %s optargs;\n" f.c_function;
        let _, bitmask = List.fold_left (
          fun (shift, bitmask) optarg ->
            let is_set =
              match optarg with
              | OBool n, "" -> false
              | OBool n, "true" ->
                  pr "    optargs.%s = 1;\n" n; true
              | OBool n, "false" ->
                  pr "    optargs.%s = 0;\n" n; true
              | OBool n, arg ->
                  failwithf "boolean optional arg '%s' should be empty string or \"true\" or \"false\"" n
              | OInt n, "" -> false
              | OInt n, i ->
                  let i =
                    try int_of_string i
                    with Failure _ -> failwithf "integer optional arg '%s' should be empty string or number" n in
                  pr "    optargs.%s = %d;\n" n i; true
              | OInt64 n, "" -> false
              | OInt64 n, i ->
                  let i =
                    try Int64.of_string i
                    with Failure _ -> failwithf "int64 optional arg '%s' should be empty string or number" n in
                  pr "    optargs.%s = %Ld;\n" n i; true
              | OString n, "NOARG" -> false
              | OString n, arg ->
                  pr "    optargs.%s = \"%s\";\n" n (c_quote arg); true
              | OStringList n, "NOARG" -> false
              | OStringList n, "" ->
                  pr "    const char *const %s[1] = { NULL };\n" n; true
              | OStringList n, arg ->
                  let strs = string_split " " arg in
                  iteri (
                    fun i str ->
                      pr "    const char *%s_%d = \"%s\";\n" n i (c_quote str);
                  ) strs;
                  pr "    const char *const %s[] = {\n" n;
                  iteri (
                    fun i _ -> pr "      %s_%d,\n" n i
                  ) strs;
                  pr "      NULL\n";
                  pr "    };\n"; true in
            let bit = if is_set then Int64.shift_left 1L shift else 0L in
            let bitmask = Int64.logor bitmask bit in
            let shift = shift + 1 in
            (shift, bitmask)
        ) (0, 0L) optargs in
        pr "    optargs.bitmask = UINT64_C(0x%Lx);\n" bitmask;
      );

      (match style_ret with
       | RErr | RInt _ | RBool _ -> pr "    int r;\n"
       | RInt64 _ -> pr "    int64_t r;\n"
       | RConstString _ | RConstOptString _ ->
           pr "    const char *r;\n"
       | RString _ -> pr "    char *r;\n"
       | RStringList _ | RHashtable _ ->
           pr "    char **r;\n";
           pr "    size_t i;\n"
       | RStruct (_, typ) ->
           pr "    struct guestfs_%s *r;\n" typ
       | RStructList (_, typ) ->
           pr "    struct guestfs_%s_list *r;\n" typ
       | RBufferOut _ ->
           pr "    char *r;\n";
           pr "    size_t size;\n"
      );

      if expect_error then
        pr "    guestfs_push_error_handler (g, NULL, NULL);\n";
      pr "    r = %s (g" f.c_function;

      (* Generate the parameters. *)
      List.iter (
        function
        | OptString _, "NULL" -> pr ", NULL"
        | Pathname n, _
        | Device n, _ | Mountable n, _ | Dev_or_Path n, _
        | String n, _
        | OptString n, _
        | Key n, _ ->
            pr ", %s" n
        | BufferIn n, _ ->
            pr ", %s, %s_size" n n
        | FileIn _, arg | FileOut _, arg ->
            pr ", \"%s\"" (c_quote arg)
        | StringList n, _ | DeviceList n, _ ->
            pr ", (char **) %s" n
        | Int _, arg ->
            let i =
              try int_of_string arg
              with Failure "int_of_string" ->
                failwithf "%s: expecting an int, but got '%s'" test_name arg in
            pr ", %d" i
        | Int64 _, arg ->
            let i =
              try Int64.of_string arg
              with Failure "int_of_string" ->
                failwithf "%s: expecting an int64, but got '%s'" test_name arg in
            pr ", %Ld" i
        | Bool _, arg ->
            let b = bool_of_string arg in pr ", %d" (if b then 1 else 0)
        | Pointer _, _ -> assert false
      ) args;

      (match style_ret with
       | RBufferOut _ -> pr ", &size"
       | _ -> ()
      );

      if optargs <> [] then
        pr ", &optargs";

      pr ");\n";

      if expect_error then
        pr "    guestfs_pop_error_handler (g);\n";

      (match errcode_of_ret style_ret, expect_error with
       | `CannotReturnError, _ -> ()
       | `ErrorIsMinusOne, false ->
           pr "    if (r == -1)\n";
           pr "      return -1;\n";
       | `ErrorIsMinusOne, true ->
           pr "    if (r != -1)\n";
           pr "      return -1;\n";
       | `ErrorIsNULL, false ->
           pr "    if (r == NULL)\n";
           pr "      return -1;\n";
       | `ErrorIsNULL, true ->
           pr "    if (r != NULL)\n";
           pr "      return -1;\n";
      );

      (* Insert the test code. *)
      (match test with
       | None -> ()
       | Some f -> f ()
      );

      (match style_ret with
       | RErr | RInt _ | RInt64 _ | RBool _
       | RConstString _ | RConstOptString _ -> ()
       | RString _ | RBufferOut _ -> pr "    free (r);\n"
       | RStringList _ | RHashtable _ ->
           pr "    for (i = 0; r[i] != NULL; ++i)\n";
           pr "      free (r[i]);\n";
           pr "    free (r);\n"
       | RStruct (_, typ) ->
           pr "    guestfs_free_%s (r);\n" typ
       | RStructList (_, typ) ->
           pr "    guestfs_free_%s_list (r);\n" typ
      );

      pr "  }\n"
