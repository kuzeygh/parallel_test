CLASS zcl_abapgit_serialize DEFINITION
  PUBLIC
  CREATE PUBLIC .

  PUBLIC SECTION.

    METHODS on_end_of_task
      IMPORTING
        !p_task TYPE clike .
    METHODS serialize
      IMPORTING
        !it_tadir            TYPE zif_abapgit_definitions=>ty_tadir_tt
        !iv_language         TYPE langu DEFAULT sy-langu
        !io_log              TYPE REF TO zcl_abapgit_log OPTIONAL
        !iv_force_sequential TYPE abap_bool DEFAULT abap_false
      RETURNING
        VALUE(rt_files)      TYPE zif_abapgit_definitions=>ty_files_item_tt
      RAISING
        zcx_abapgit_exception .
  PROTECTED SECTION.

    DATA mt_files TYPE zif_abapgit_definitions=>ty_files_item_tt .
    DATA mv_free TYPE i .

    METHODS add_to_return
      IMPORTING
        !iv_path      TYPE string
        !is_fils_item TYPE zcl_abapgit_objects=>ty_serialization .
    METHODS run_parallel
      IMPORTING
        !iv_group    TYPE rzlli_apcl
        !is_tadir    TYPE zif_abapgit_definitions=>ty_tadir
        !iv_language TYPE langu
      RAISING
        zcx_abapgit_exception .
    METHODS run_sequential
      IMPORTING
        !is_tadir    TYPE zif_abapgit_definitions=>ty_tadir
        !iv_language TYPE langu
        !io_log      TYPE REF TO zcl_abapgit_log
      RAISING
        zcx_abapgit_exception .
    METHODS determine_max_threads
      IMPORTING
        !iv_force_sequential TYPE abap_bool DEFAULT abap_false
      RETURNING
        VALUE(rv_threads)    TYPE i
      RAISING
        zcx_abapgit_exception .
  PRIVATE SECTION.
ENDCLASS.



CLASS ZCL_ABAPGIT_SERIALIZE IMPLEMENTATION.


  METHOD add_to_return.

    FIELD-SYMBOLS: <ls_file>   LIKE LINE OF is_fils_item-files,
                   <ls_return> LIKE LINE OF mt_files.


    LOOP AT is_fils_item-files ASSIGNING <ls_file>.
      APPEND INITIAL LINE TO mt_files ASSIGNING <ls_return>.
      <ls_return>-file = <ls_file>.
      <ls_return>-file-path = iv_path.
      <ls_return>-item = is_fils_item-item.
    ENDLOOP.

  ENDMETHOD.


  METHOD determine_max_threads.

    IF iv_force_sequential = abap_true.
      rv_threads = 1.
      RETURN.
    ENDIF.

    CALL FUNCTION 'FUNCTION_EXISTS'
      EXPORTING
        funcname           = 'Z_ABAPGIT_SERIALIZE_PARALLEL'
      EXCEPTIONS
        function_not_exist = 1
        OTHERS             = 2.
    IF sy-subrc <> 0.
      rv_threads = 1.
      RETURN.
    ENDIF.

* todo, add possibility to set group name in user exit

    CALL FUNCTION 'SPBT_INITIALIZE'
      EXPORTING
        group_name                     = 'parallel_generators'
      IMPORTING
        free_pbt_wps                   = rv_threads
      EXCEPTIONS
        invalid_group_name             = 1
        internal_error                 = 2
        pbt_env_already_initialized    = 3
        currently_no_resources_avail   = 4
        no_pbt_resources_found         = 5
        cant_init_different_pbt_groups = 6
        OTHERS                         = 7.
    IF sy-subrc <> 0.
      zcx_abapgit_exception=>raise( |Error from SPBT_INITIALIZE: { sy-subrc }| ).
    ENDIF.

    ASSERT rv_threads >= 1.

  ENDMETHOD.


  METHOD on_end_of_task.

    DATA: lv_result    TYPE xstring,
          lv_path      TYPE string,
          ls_fils_item TYPE zcl_abapgit_objects=>ty_serialization.


    RECEIVE RESULTS FROM FUNCTION 'Z_ABAPGIT_SERIALIZE_PARALLEL'
      IMPORTING
        ev_result = lv_result
        ev_path   = lv_path
      EXCEPTIONS
        error     = 1
        OTHERS    = 2.
    IF sy-subrc <> 0.
      WRITE: / 'error, receive'.
* todo, error handling
    ENDIF.

    IMPORT data = ls_fils_item FROM DATA BUFFER lv_result.

    add_to_return( is_fils_item = ls_fils_item
                   iv_path      = lv_path ).

    mv_free = mv_free + 1.

  ENDMETHOD.


  METHOD run_parallel.

    DATA: lv_task TYPE c LENGTH 44.


    ASSERT mv_free > 0.

    CONCATENATE is_tadir-object is_tadir-obj_name INTO lv_task.

* todo, how to handle setting "<ls_file>-path = <ls_tadir>-path." ?
    CALL FUNCTION 'Z_ABAPGIT_SERIALIZE_PARALLEL'
      STARTING NEW TASK lv_task
      DESTINATION IN GROUP iv_group
      CALLING on_end_of_task ON END OF TASK
      EXPORTING
        iv_obj_type           = is_tadir-object
        iv_obj_name           = is_tadir-obj_name
        iv_devclass           = is_tadir-devclass
        iv_language           = iv_language
        iv_path               = is_tadir-path
      EXCEPTIONS
        system_failure        = 1
        communication_failure = 2
        resource_failure      = 3.
    IF sy-subrc = 3.
      WRITE: / 'resource failure, wait'.
      WAIT UP TO 1 SECONDS.
    ELSEIF sy-subrc <> 0.
      WRITE: / 'error, calling', sy-subrc.
      RETURN.
    ENDIF.

    mv_free = mv_free - 1.

  ENDMETHOD.


  METHOD run_sequential.

    DATA: ls_fils_item TYPE zcl_abapgit_objects=>ty_serialization.


    ls_fils_item-item-obj_type = is_tadir-object.
    ls_fils_item-item-obj_name = is_tadir-obj_name.
    ls_fils_item-item-devclass = is_tadir-devclass.

    ls_fils_item = zcl_abapgit_objects=>serialize(
      is_item     = ls_fils_item-item
      iv_language = iv_language
      io_log      = io_log ).

    add_to_return( is_fils_item = ls_fils_item
                   iv_path      = is_tadir-path ).

  ENDMETHOD.


  METHOD serialize.

    DATA: lv_max       TYPE i,
          ls_fils_item TYPE zcl_abapgit_objects=>ty_serialization.

    FIELD-SYMBOLS: <ls_tadir>  LIKE LINE OF it_tadir.


* todo, handle "unsupported object type" in log, https://github.com/larshp/abapGit/issues/2121
* todo, progress indicator?

    CLEAR mt_files.

    lv_max = determine_max_threads( iv_force_sequential ).
    WRITE: / 'max', lv_max.
    mv_free = lv_max.

    LOOP AT it_tadir ASSIGNING <ls_tadir>.
      IF lv_max = 1.
        run_sequential(
          is_tadir    = <ls_tadir>
          iv_language = iv_language
          io_log      = io_log ).
      ELSE.
        run_parallel(
          iv_group    = 'parallel_generators'    " todo
          is_tadir    = <ls_tadir>
          iv_language = iv_language ).
        WAIT UNTIL mv_free > 0 UP TO 10 SECONDS.
      ENDIF.
    ENDLOOP.

    WAIT UNTIL mv_free = lv_max UP TO 10 SECONDS.
    rt_files = mt_files.

  ENDMETHOD.
ENDCLASS.
