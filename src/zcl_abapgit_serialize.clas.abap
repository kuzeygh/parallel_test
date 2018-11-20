class ZCL_ABAPGIT_SERIALIZE definition
  public
  final
  create public .

public section.

  methods ON_END_OF_TASK
    importing
      !P_TASK type CLIKE .
  methods SERIALIZE
    importing
      !IT_TADIR type ZIF_ABAPGIT_DEFINITIONS=>TY_TADIR_TT
      !IV_LANGUAGE type LANGU
      !IO_LOG type ref to ZCL_ABAPGIT_LOG
    returning
      value(RT_FILES) type ZIF_ABAPGIT_DEFINITIONS=>TY_FILES_ITEM_TT
    raising
      ZCX_ABAPGIT_EXCEPTION .
protected section.

  data MT_FILES type ZIF_ABAPGIT_DEFINITIONS=>TY_FILES_ITEM_TT .

  methods DETERMINE_MAX_THREADS
    returning
      value(RV_THREADS) type I
    raising
      ZCX_ABAPGIT_EXCEPTION .
private section.
ENDCLASS.



CLASS ZCL_ABAPGIT_SERIALIZE IMPLEMENTATION.


  METHOD determine_max_threads.

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


  method ON_END_OF_TASK.
  endmethod.


  METHOD serialize.

    DATA: lv_task      TYPE c LENGTH 5,
          lv_max       TYPE i,
          ls_fils_item TYPE zcl_abapgit_objects=>ty_serialization,
          lv_free      TYPE i.

    FIELD-SYMBOLS: <ls_file>   LIKE LINE OF ls_fils_item-files,
                   <ls_return> LIKE LINE OF rt_files,
                   <ls_tadir>  LIKE LINE OF it_tadir.


* todo, handle "unsupported object type" in log

    CLEAR mt_files.

    lv_max = determine_max_threads( ).
    lv_free = lv_max.

    LOOP AT it_tadir ASSIGNING <ls_tadir>.
      lv_task = sy-tabix.

      IF lv_max = 1.

        ls_fils_item = zcl_abapgit_objects=>serialize(
          is_item     = ls_fils_item-item
          iv_language = iv_language
          io_log      = io_log ).

        LOOP AT ls_fils_item-files ASSIGNING <ls_file>.
          <ls_file>-path = <ls_tadir>-path.

          APPEND INITIAL LINE TO rt_files ASSIGNING <ls_return>.
          <ls_return>-file = <ls_file>.
          <ls_return>-item = ls_fils_item-item.
        ENDLOOP.

      ELSE.
        CALL FUNCTION 'Z_ABAPGIT_SERIALIZE_PARALLEL'
          STARTING NEW TASK lv_task
          CALLING on_end_of_task ON END OF TASK
          EXPORTING
            obj_type = <ls_tadir>-object
            obj_name = <ls_tadir>-obj_name
            devclass = <ls_tadir>-devclass
            language = iv_language
          EXCEPTIONS
            error    = 1
            OTHERS   = 2.
        IF sy-subrc <> 0.
          BREAK-POINT.
        ENDIF.

        lv_free = lv_free - 1.

        WAIT UNTIL lv_free > 0.
      ENDIF.

    ENDLOOP.

    WAIT UNTIL lv_free = lv_max.

    rt_files = mt_files.

  ENDMETHOD.
ENDCLASS.
