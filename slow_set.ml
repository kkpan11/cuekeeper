(* Copyright (C) 2015, Thomas Leonard
 * See the README file for details. *)

open Lwt

type 'a state =
  [ `New
  | `Moved of 'a option ref    (* Ref is shared with removed item *)
  | `Current
  | `Removed of 'a option ref * float ] (* Time item was removed from input *)

module type ITEM = sig
  include Map.OrderedType
  val id : t -> Ck_id.t
end

type ('a, 'b) item = {
  data : 'a;
  state : 'b state React.S.t;
  set_state : 'b state -> unit;
}

let data item = item.data
let state item = item.state

let make_item initial_state data =
  let state, set_state = React.S.create initial_state in
  {data; state; set_state}

module Make (C : Ck_clock.S) (I : ITEM) (M : Map.S with type key = I.t) = struct
  let diff_old_new ~removed_by_id ~time key i_old i_new =
    match i_old, i_new with
    | None, None -> None
    | Some _, None ->
        let cell = ref None in
        removed_by_id := !removed_by_id |> Ck_id.M.add (I.id key) cell;
        Some (`Removed (cell, time))
    | None, Some n -> Some (`New n)
    | Some o, Some n when o <> n -> Some (`Updated n)
    | Some _, Some _ -> None

  let merge_diff _key prev patch =
    match prev, patch with
    | prev, None -> prev
    | Some old as prev, Some ((`Removed _) as r) -> old.set_state r; prev
    | Some old, Some (`Updated data) -> Some {old with data}
    | None, Some (`New data) -> Some (make_item `New data)
    | None, Some (`Moved (data, cell)) -> Some (make_item (`Moved cell) data)
    | Some old, Some (`New data | `Moved (data, _)) -> old.set_state `Current; Some {old with data}
    | None, Some (`Updated _ | `Removed _) -> assert false

  let detect_moves ~removed_by_id =
    M.mapi (fun k v ->
      match v with
      | (`New data) as p ->
          begin try
            let cell = Ck_id.M.find (I.id k) removed_by_id in
            `Moved (data, cell)
          with Not_found -> p end
      | p -> p
    )

  let make ~delay ~eq ?init input =
    let init =
      match init with
      | None -> React.S.value input
      | Some i -> i in

    let out_item_eq a b = eq a.data b.data in

    let output, set_output =
      init
      |> M.map (make_item `Current)
      |> React.S.create ~eq:(M.equal out_item_eq) in

    (* Called [delay] after some items have been added or removed.
     * Update their status if appropriate. *)
    let check start delayed =
      let m = ref (React.S.value output) in
      delayed |> M.iter (fun k _v ->
        let item = M.find k !m in
        match React.S.value item.state with
        | `New | `Moved _ -> item.set_state `Current
        | `Removed (_, t) when t = start -> m := !m |> M.remove k
        | `Current | `Removed _ -> ()
      );
      set_output !m in

    let keep_me =
      input |> React.S.diff (fun s_new s_old ->
        let time = C.now () in
        let removed_by_id = ref Ck_id.M.empty in
        let diff =
          M.merge (diff_old_new ~removed_by_id ~time) s_old s_new
          |> detect_moves ~removed_by_id:!removed_by_id in

        if not (M.is_empty diff) then (
          M.merge merge_diff (React.S.value output) diff
          |> set_output;
          C.async (fun () ->
            C.sleep delay >|= fun () ->
            check time diff
          )
        )
      ) in
    React.S.retain output (fun () -> ignore keep_me) |> ignore;

    output
end