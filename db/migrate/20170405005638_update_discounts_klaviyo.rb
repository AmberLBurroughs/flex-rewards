class UpdateDiscountsKlaviyo < ActiveRecord::Migration[5.0]
  def change
    change_table :discounts do |t|
      t.column :first_name, :string
      t.column :last_name, :string
      t.column :klaviyo_synced, :boolean
    end
  end
end
